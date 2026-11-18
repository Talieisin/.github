// tfguard: the caersid #602 rules for one Terraform tier, applied to the
// files Terraform loads, with a real HCL parser (hashicorp/hcl/v2).
//
//	tfguard <tier> <head terraform root> <base terraform root>
//
// The roots are infrastructure/terraform of the pull request's head and of
// main. Exit 0: every rule holds ("ok: ..." on stdout). Exit 3: a rule
// refuses (one line on stdout, the reason). Exit 2: usage or an error. It
// fails closed: anything it cannot read, parse or classify refuses.
//
// The rules:
//   - Every entry of the tier is a regular file or directory with a name of
//     [A-Za-z0-9._-] that does not start with "..". No symbolic link, no
//     terraform.d or .terraform directory, no configuration (*.tf, *.tf.json,
//     *.tofu, *.tofu.json) below the tier's root, no override or JSON or
//     .tofu configuration at the root.
//   - Byte-identical to main's (or absent from both): .terraform.lock.hcl,
//     the tier's environments/<tier>-production.tfvars, terraform.tfvars(.json)
//     and every *.auto.tfvars(.json).
//   - Every root .tf file parses, and its top level holds only blocks.
//   - No module block.
//   - The terraform, provider and data "terraform_remote_state" blocks are
//     structurally equal to main's (attributes compared as token sequences
//     without comments or layout, as a multiset, whichever file holds them),
//     and so is everything they reference, transitively: variable blocks
//     (their defaults included), locals, data sources and resources.
//   - In every block the pull request adds or changes (one whose canonical
//     form is not among main's):
//   - no provider-defined function (name containing "::") and no
//     function that reads files (file, fileset, templatefile, ...);
//   - count and for_each reference nothing (no variable, local,
//     resource, data or path): the summary shows instances;
//   - a data source is not external, http, terraform_remote_state or
//     azurerm_key_vault_encrypted_value, and its type is one main already
//     uses; nested data sources in a check block likewise;
//   - no ephemeral, action, module or unknown block type.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"
)

// refusal is a rule's verdict: exit 3 with its message.
type refusal struct{ msg string }

func (r refusal) Error() string { return r.msg }

func refuse(format string, a ...any) error { return refusal{fmt.Sprintf(format, a...)} }

var safeName = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

var fileFunctions = map[string]bool{
	"file": true, "filebase64": true, "fileexists": true, "fileset": true,
	"filemd5": true, "filesha1": true, "filesha256": true, "filesha512": true,
	"filebase64sha256": true, "filebase64sha512": true, "templatefile": true,
}

var deniedData = map[string]bool{
	"external": true, "http": true, "terraform_remote_state": true,
	"azurerm_key_vault_encrypted_value": true,
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: tfguard <tier> <head terraform root> <base terraform root>")
		os.Exit(2)
	}
	msg, err := check(os.Args[1], os.Args[2], os.Args[3])
	var r refusal
	switch {
	case err == nil:
		fmt.Println(msg)
	case errors.As(err, &r):
		fmt.Println(r.msg)
		os.Exit(3)
	default:
		fmt.Fprintln(os.Stderr, "tfguard:", err)
		os.Exit(2)
	}
}

func check(tier, headRoot, baseRoot string) (string, error) {
	if tier != "platform" && tier != "compute" {
		return "", fmt.Errorf("unknown tier %q", tier)
	}
	head := filepath.Join(headRoot, tier)
	base := filepath.Join(baseRoot, tier)
	if err := checkTree(head); err != nil {
		return "", err
	}
	if fi, err := os.Lstat(base); err != nil || !fi.IsDir() {
		return "", fmt.Errorf("main has no %s tier", tier)
	}

	// Byte-identical files.
	tfvars := filepath.Join("environments", tier+"-production.tfvars")
	if err := sameBytes(filepath.Join(headRoot, tfvars), filepath.Join(baseRoot, tfvars), "the tier's tfvars file"); err != nil {
		return "", err
	}
	if err := sameBytes(filepath.Join(head, ".terraform.lock.hcl"), filepath.Join(base, ".terraform.lock.hcl"), ".terraform.lock.hcl"); err != nil {
		return "", err
	}
	names, err := rootNames(head, base)
	if err != nil {
		return "", err
	}
	for _, n := range names {
		if n == "terraform.tfvars" || n == "terraform.tfvars.json" || strings.HasSuffix(n, ".auto.tfvars") || strings.HasSuffix(n, ".auto.tfvars.json") {
			if err := sameBytes(filepath.Join(head, n), filepath.Join(base, n), n); err != nil {
				return "", err
			}
		}
	}

	// Parse both sides.
	hm, err := load(head, true)
	if err != nil {
		return "", err
	}
	bm, err := load(base, false)
	if err != nil {
		return "", err
	}

	// Frozen blocks: equal as a multiset.
	if !equalMultiset(hm.frozen, bm.frozen) {
		return "", refuse("the tier's terraform, provider or remote-state configuration differs from main's. Those are never planned in CI.")
	}
	// Everything they reference, transitively.
	seen := map[string]bool{}
	var queue []string
	for _, b := range hm.frozenBlocks {
		queue = append(queue, refsOf(b)...)
	}
	for len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		if seen[id] {
			continue
		}
		seen[id] = true
		if id == "module" {
			return "", refuse("the provider or remote-state configuration references a module.")
		}
		h, okH := hm.items[id]
		b, okB := bm.items[id]
		if !okH || !okB || h.canon != b.canon {
			return "", refuse("%s, which the provider or remote-state configuration uses, differs from main's.", id)
		}
		queue = append(queue, h.refs...)
	}

	// Blocks the pull request adds or changes.
	baseCanon := map[string]int{}
	baseDataTypes := map[string]bool{}
	for _, it := range bm.items {
		baseCanon[it.canon]++
	}
	for _, t := range bm.dataTypes {
		baseDataTypes[t] = true
	}
	ids := make([]string, 0, len(hm.items))
	for id := range hm.items {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		it := hm.items[id]
		if baseCanon[it.canon] > 0 {
			baseCanon[it.canon]--
			continue
		}
		if err := checkChanged(id, it, baseDataTypes); err != nil {
			return "", err
		}
	}
	return fmt.Sprintf("ok: the %s tier's rules hold", tier), nil
}

// checkTree walks the tier without following links.
func checkTree(root string) error {
	fi, err := os.Lstat(root)
	if err != nil || !fi.IsDir() {
		return refuse("the tier directory is missing or not a directory.")
	}
	return filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == root {
			return nil
		}
		name := d.Name()
		if !safeName.MatchString(name) || strings.HasPrefix(name, "..") {
			return refuse("the tier has a file or directory whose name is not letters, digits, '.', '_' or '-'.")
		}
		t := d.Type()
		switch {
		case t&fs.ModeSymlink != 0:
			return refuse("the tier contains a symbolic link.")
		case d.IsDir():
			if name == "terraform.d" || name == ".terraform" {
				return refuse("the tier has a %s directory.", name)
			}
			return nil
		case !t.IsRegular():
			return refuse("the tier contains something that is neither a file nor a directory.")
		}
		rel, _ := filepath.Rel(root, p)
		depth := strings.Count(rel, string(filepath.Separator))
		config := strings.HasSuffix(name, ".tf") || strings.HasSuffix(name, ".tf.json") ||
			strings.HasSuffix(name, ".tofu") || strings.HasSuffix(name, ".tofu.json")
		if depth > 0 && config {
			return refuse("a subdirectory of the tier holds Terraform configuration (a module). Modules are never planned in CI.")
		}
		if depth == 0 && config && !strings.HasSuffix(name, ".tf") {
			return refuse("the tier has %s: JSON and .tofu configuration are never planned in CI.", name)
		}
		if depth == 0 && (name == "override.tf" || strings.HasSuffix(name, "_override.tf")) {
			return refuse("the tier has an override file, %s.", name)
		}
		return nil
	})
}

// sameBytes: both absent, or both regular files with the same content.
func sameBytes(head, base, label string) error {
	h, herr := readRegular(head)
	b, berr := readRegular(base)
	if errors.Is(herr, fs.ErrNotExist) && errors.Is(berr, fs.ErrNotExist) {
		return nil
	}
	if herr != nil || berr != nil || !bytes.Equal(h, b) {
		return refuse("%s differs from main's. That is never planned in CI.", label)
	}
	return nil
}

func readRegular(p string) ([]byte, error) {
	fi, err := os.Lstat(p)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", p)
	}
	return os.ReadFile(p)
}

func rootNames(dirs ...string) ([]string, error) {
	set := map[string]bool{}
	for _, d := range dirs {
		es, err := os.ReadDir(d)
		if err != nil {
			return nil, err
		}
		for _, e := range es {
			if !e.IsDir() {
				set[e.Name()] = true
			}
		}
	}
	out := make([]string, 0, len(set))
	for n := range set {
		out = append(out, n)
	}
	sort.Strings(out)
	return out, nil
}

type item struct {
	kind  string // block type, or "local"
	canon string
	refs  []string
	node  hclsyntax.Node
	block *hclsyntax.Block // nil for a local
}

type model struct {
	frozen       []string
	frozenBlocks []*hclsyntax.Block
	items        map[string]*item
	dataTypes    []string
}

// load parses every root .tf file of a tier. isHead: a refusal rather than an
// error when something is wrong (main is trusted to parse).
func load(dir string, isHead bool) (*model, error) {
	fail := func(format string, a ...any) error {
		if isHead {
			return refuse(format, a...)
		}
		return fmt.Errorf("main: "+format, a...)
	}
	es, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	m := &model{items: map[string]*item{}}
	var names []string
	for _, e := range es {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".tf") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names {
		src, err := readRegular(filepath.Join(dir, name))
		if err != nil {
			return nil, fail("%s cannot be read.", name)
		}
		f, diags := hclsyntax.ParseConfig(src, name, hcl.InitialPos)
		if diags.HasErrors() {
			return nil, fail("%s does not parse as HCL.", name)
		}
		body, ok := f.Body.(*hclsyntax.Body)
		if !ok {
			return nil, fail("%s does not parse as HCL native syntax.", name)
		}
		if len(body.Attributes) > 0 {
			return nil, fail("%s has an attribute at the top level.", name)
		}
		for _, b := range body.Blocks {
			canon, err := canonBlock(b, src)
			if err != nil {
				return nil, fail("%s: %v", name, err)
			}
			add := func(id string, it *item) error {
				if _, dup := m.items[id]; dup {
					return fail("%s: %s is declared twice.", name, id)
				}
				m.items[id] = it
				return nil
			}
			switch b.Type {
			case "terraform", "provider":
				m.frozen = append(m.frozen, canon)
				m.frozenBlocks = append(m.frozenBlocks, b)
			case "module":
				return nil, fail("%s has a module block. Modules are never planned in CI.", name)
			case "data":
				if len(b.Labels) != 2 {
					return nil, fail("%s: a data block without two labels.", name)
				}
				if b.Labels[0] == "terraform_remote_state" {
					m.frozen = append(m.frozen, canon)
					m.frozenBlocks = append(m.frozenBlocks, b)
					continue
				}
				m.dataTypes = append(m.dataTypes, b.Labels[0])
				if err := add("data."+b.Labels[0]+"."+b.Labels[1], &item{kind: "data", canon: canon, refs: refsOf(b), node: b, block: b}); err != nil {
					return nil, err
				}
			case "resource", "ephemeral":
				if len(b.Labels) != 2 {
					return nil, fail("%s: a %s block without two labels.", name, b.Type)
				}
				id := b.Labels[0] + "." + b.Labels[1]
				if b.Type == "ephemeral" {
					id = "ephemeral." + id
				}
				if err := add(id, &item{kind: b.Type, canon: canon, refs: refsOf(b), node: b, block: b}); err != nil {
					return nil, err
				}
			case "variable", "output", "check":
				if len(b.Labels) != 1 {
					return nil, fail("%s: a %s block without one label.", name, b.Type)
				}
				prefix := map[string]string{"variable": "var.", "output": "output.", "check": "check."}[b.Type]
				refs := refsOf(b)
				if b.Type == "variable" {
					// A variable's value comes from its default and the
					// (frozen) variable files; its type and validation are
					// compared as part of its canonical form. Its type
					// keywords (string, list, ...) are not references.
					refs = nil
				}
				if err := add(prefix+b.Labels[0], &item{kind: b.Type, canon: canon, refs: refs, node: b, block: b}); err != nil {
					return nil, err
				}
			case "locals":
				for _, a := range sortedAttrs(b.Body) {
					ec, err := canonExpr(a.Expr, src)
					if err != nil {
						return nil, fail("%s: %v", name, err)
					}
					if err := add("local."+a.Name, &item{kind: "local", canon: "local " + a.Name + "=" + ec, refs: refsOfExpr(a.Expr), node: a.Expr}); err != nil {
						return nil, err
					}
				}
			default:
				// import, moved, removed, action and anything newer: keyed by
				// their whole canonical form, so any change is "changed".
				if err := add(b.Type+"#"+canon, &item{kind: b.Type, canon: canon, refs: refsOf(b), node: b, block: b}); err != nil {
					return nil, err
				}
			}
		}
	}
	sort.Strings(m.frozen)
	return m, nil
}

func sortedAttrs(body *hclsyntax.Body) []*hclsyntax.Attribute {
	out := make([]*hclsyntax.Attribute, 0, len(body.Attributes))
	for _, a := range body.Attributes {
		out = append(out, a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// canonBlock: type, labels, attributes in name order (each a token sequence
// without comments or layout), then nested blocks in order.
func canonBlock(b *hclsyntax.Block, src []byte) (string, error) {
	var sb strings.Builder
	sb.WriteString(b.Type)
	for _, l := range b.Labels {
		fmt.Fprintf(&sb, " %q", l)
	}
	sb.WriteString(" {")
	for _, a := range sortedAttrs(b.Body) {
		ec, err := canonExpr(a.Expr, src)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&sb, " %s=%s;", a.Name, ec)
	}
	for _, nb := range b.Body.Blocks {
		c, err := canonBlock(nb, src)
		if err != nil {
			return "", err
		}
		sb.WriteString(" " + c)
	}
	sb.WriteString(" }")
	return sb.String(), nil
}

// canonExpr: the expression's own tokens, without comments and newlines,
// separated by single spaces.
func canonExpr(e hclsyntax.Expression, src []byte) (string, error) {
	r := e.Range()
	if r.Start.Byte < 0 || r.End.Byte > len(src) || r.Start.Byte > r.End.Byte {
		return "", errors.New("an expression's source range is not in the file")
	}
	toks, diags := hclsyntax.LexExpression(src[r.Start.Byte:r.End.Byte], r.Filename, r.Start)
	if diags.HasErrors() {
		return "", errors.New("an expression does not lex")
	}
	parts := make([]string, 0, len(toks))
	for _, t := range toks {
		switch t.Type {
		case hclsyntax.TokenComment, hclsyntax.TokenNewline, hclsyntax.TokenEOF:
			continue
		}
		parts = append(parts, string(t.Bytes))
	}
	return strings.Join(parts, " "), nil
}

// refsOf: the ids a block's expressions reference (var.x, local.x, data.t.n,
// t.n), and "module" for any module reference.
func refsOf(b *hclsyntax.Block) []string {
	var out []string
	for _, a := range b.Body.Attributes {
		out = append(out, refsOfExpr(a.Expr)...)
	}
	for _, nb := range b.Body.Blocks {
		out = append(out, refsOf(nb)...)
	}
	return out
}

func refsOfExpr(e hclsyntax.Expression) []string {
	var out []string
	for _, t := range e.Variables() {
		root := t.RootName()
		attr := func(i int) string {
			if i < len(t) {
				if a, ok := t[i].(hcl.TraverseAttr); ok {
					return a.Name
				}
			}
			return ""
		}
		switch root {
		case "var":
			out = append(out, "var."+attr(1))
		case "local":
			out = append(out, "local."+attr(1))
		case "data":
			out = append(out, "data."+attr(1)+"."+attr(2))
		case "ephemeral":
			out = append(out, "ephemeral."+attr(1)+"."+attr(2))
		case "module":
			out = append(out, "module")
		case "path", "terraform", "each", "count", "self":
		default:
			out = append(out, root+"."+attr(1))
		}
	}
	return out
}

func equalMultiset(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// checkChanged: the rules for a block the pull request adds or changes.
func checkChanged(id string, it *item, baseDataTypes map[string]bool) error {
	switch it.kind {
	case "data", "resource", "variable", "output", "check", "local", "import", "moved", "removed":
	case "ephemeral":
		return refuse("the pull request adds or changes an ephemeral resource. Those are never planned in CI.")
	default:
		return refuse("the pull request adds or changes a %s block, which this check does not plan.", it.kind)
	}
	if it.kind == "data" {
		if err := checkData(it.block.Labels[0], baseDataTypes); err != nil {
			return err
		}
	}
	var verr error
	hclsyntax.VisitAll(it.node, func(n hclsyntax.Node) hcl.Diagnostics {
		if verr != nil {
			return nil
		}
		switch x := n.(type) {
		case *hclsyntax.FunctionCallExpr:
			if strings.Contains(x.Name, "::") {
				verr = refuse("%s calls a provider-defined function. Those are never planned in CI.", id)
			} else if fileFunctions[x.Name] {
				verr = refuse("%s calls %s(), which reads files. That is never planned in CI.", id, x.Name)
			}
		case *hclsyntax.Block:
			if x.Type == "data" && it.kind == "check" {
				if len(x.Labels) != 2 {
					verr = refuse("%s has a data block without two labels.", id)
				} else if err := checkData(x.Labels[0], baseDataTypes); err != nil {
					verr = err
				}
			}
		}
		return nil
	})
	if verr != nil {
		return verr
	}
	if it.block != nil && (it.kind == "resource" || it.kind == "data") {
		for _, name := range []string{"count", "for_each"} {
			if a, ok := it.block.Body.Attributes[name]; ok && len(a.Expr.Variables()) > 0 {
				return refuse("%s has a %s that references a value. Only literal count and for_each are planned in CI.", id, name)
			}
		}
	}
	return nil
}

func checkData(typ string, baseDataTypes map[string]bool) error {
	if deniedData[typ] {
		return refuse("the pull request adds or changes a %s data source. That is never planned in CI.", typ)
	}
	if !baseDataTypes[typ] {
		return refuse("the pull request adds a %s data source, a type main does not use. New data source types are never planned in CI.", typ)
	}
	return nil
}
