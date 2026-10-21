# AGENTS.md

Guia para agentes de código neste repositório. Visão de produto, diagrama, pré-requisitos e ordem de aplicação estão no [README.md](README.md); aqui ficam as regras para **alterar** o código.

## O que é

Template Terraform da conta de workload "AI Platform" (AWS, **sa-east-1**): Bedrock + AgentCore (Runtime, Gateway, Identity, Policy), OpenSearch Serverless, API Gateway privado, ALB/WAF e baseline de segurança. Piloto: copiloto interno da central de atendimento, tools somente leitura.

## Layout

| Caminho | Papel |
|---|---|
| `modules/<nome>/` | Módulos reutilizáveis. Estrutura fixa: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` (arquivos extras por tema, ex.: `network/egress.tf`, `tool-gateway/targets.tf`). |
| `envs/dev`, `envs/prd` | Root modules da conta de workload. Compõem os módulos. |
| `stacks/org-guardrails` | SCPs, aplicado na conta de gerenciamento. Usa `modules/org-guardrails`. |
| `specs/openapi/*.json.tftpl` | Specs OpenAPI das tools; renderizadas por `templatefile` em `modules/tool-gateway/targets.tf`. |
| `.github/workflows/terraform.yml` | CI: fmt · validate · tflint · checkov · plan. |

## Comandos de verificação

Rode antes de concluir qualquer alteração (os mesmos passos do CI):

```bash
terraform fmt -check -recursive -diff

for dir in envs/dev envs/prd stacks/org-guardrails; do
  terraform -chdir="$dir" init -backend=false -input=false
  terraform -chdir="$dir" validate
done

tflint --init --config "$PWD/.tflint.hcl"
tflint --recursive --config "$PWD/.tflint.hcl" --format compact

checkov --config-file .checkov.yaml
```

Versões do CI: Terraform `~1.13.0`, tflint `0.64.0` (ruleset aws `0.49.0`), checkov `3.3.30`. OpenTofu 1.13 serve para `fmt`/`validate` local. Se alguma ferramenta não estiver instalada, diga isso no resultado em vez de declarar a verificação como feita.

**Nunca** rode `terraform apply`, `destroy`, `import` ou `state *` nem `init` com backend real. Plan contra a AWS só com pedido explícito do usuário.

## Regras de dev ↔ prd

- `envs/dev` e `envs/prd` são espelhos: `variables.tf`, `outputs.tf`, `providers.tf`, `versions.tf` e `terraform.tfvars.example` devem ficar idênticos (exceto valores do exemplo).
- `main.tf` de prd difere **só** pelas preconditions extras de produção em `terraform_data.registry_checks` (ENFORCE, `force_destroy=false`, `deletion_protection`, Object Lock `COMPLIANCE`).
- Toda mudança em um ambiente vale para o outro. Confira com `diff envs/dev/<arquivo> envs/prd/<arquivo>`.
- Variável nova em módulo exposta ao root: declare nos dois `variables.tf` e no `terraform.tfvars.example` de ambos.

## Convenções de código

- **Idioma:** descrições, comentários, `error_message` e textos de validação em português. Identificadores (variáveis, recursos, outputs) em inglês, `snake_case`.
- **Variáveis/outputs:** sempre com `description` e `type` (tflint exige `terraform_documented_*` e `terraform_typed_variables`). Sem declarações não usadas.
- **Validações:** prefira `validation` na variável e `precondition` em `terraform_data.registry_checks` para regras entre variáveis. O plan deve falhar cedo com mensagem clara.
- **Seções:** separadores no formato `# ------------------------------------------- Título ----` (alinhado à direita), como nos arquivos existentes.
- **Providers:** `hashicorp/aws ~> 6.69` para tudo. `hashicorp/awscc ~> 1.106` **só** onde o `aws` não cobre (hoje: `awscc_opensearchserverless_collection_index`). Não adicione outros providers nem módulos do registry; `call_module_type = "local"`.
- **Tags:** `default_tags` no provider. Recursos de um caso de uso sobrescrevem `use_case` com a chave do caso (é cost allocation tag).
- **Buckets S3:** use `modules/s3-secure-bucket` (KMS, versionamento, PAB, TLS obrigatório, Object Lock opcional). Não crie `aws_s3_bucket` solto.
- **Criptografia:** CMKs de `modules/kms` (`logs`, `data`, `kb`). Log groups, buckets e coleções sempre com KMS.

## Checkov

- O build falha em **qualquer** check. Não adicione `skip-check` em `.checkov.yaml`.
- Exceção só no próprio recurso: `#checkov:skip=<ID>:<justificativa em português>`. Justificativa concreta, como em `modules/kms/main.tf`.

## Invariantes de segurança (não quebrar)

Mudanças que violem estes pontos precisam de pedido explícito do usuário e devem ser sinalizadas:

1. **Sem credenciais estáticas.** Nada de `aws_iam_user`, access keys, segredos em código ou em `*.tfvars` (ignorados pelo git). Credenciais via OIDC/SSO; o único segredo (client secret do ALB) vem do Secrets Manager por ARN.
2. **Sem internet nas subnets de workload.** Nenhuma rota `0.0.0.0/0 → IGW`; tráfego AWS por VPC endpoints. Egress externo só via Network Firewall quando `egress_allowed_domains` não estiver vazio.
3. **Todo LLM via Bedrock.** Role do caso de uso: `InvokeModel*` só nos inference profiles do caso, deny sem o guardrail/versão do caso. Nada de LiteLLM ou gateway de terceiros.
4. **Toda tool via AgentCore Gateway + Cedar.** Tools `write` não recebem permit e o plan falha com `allow_write_tools = false`.
5. **Residência de dados.** Só modelos/profiles in-region; perfis `us.`/`global.` bloqueados por validação e SCP.
6. **Registro fechado.** Caso de uso fora de `use_cases`, modelo fora de `allowed_model_ids` ou tool fora de `tools` → plan falha. Mantenha essas preconditions.
7. **Menor privilégio.** Policies IAM com `Resource` específico; `"*"` só onde a API exige, com justificativa.

## Tarefas comuns

- **Novo caso de uso:** entrada em `use_cases` nos `terraform.tfvars.example` (dev e prd). O `for_each` cria profile, role, guardrail, runtime e budget; não crie recursos manuais por caso.
- **Nova tool:** entrada em `tools` (`effect`, escopos, operationIds) + spec em `specs/openapi/<tool>.json.tftpl`. Leitura apenas, salvo pedido explícito.
- **Novo módulo:** os quatro arquivos padrão, `versions.tf` com `required_version >= 1.6` e só os providers usados; inclua na tabela "Mapeamento componente → módulo" do README.
- **Recurso singleton de conta** (Config, GuardDuty, Macie, `aws_api_gateway_account`, outbound identity federation): proteja com toggle `enable_*`.

## Pendências conhecidas

O README lista TODOs bloqueantes (disponibilidade em sa-east-1, esquema Cedar, ações IAM do policy engine, `index_schema` do `awscc`). Ao tocar nessas áreas, não trate o comportamento como validado; mantenha ou atualize a seção "Premissas e TODOs" do README.

## Documentação

Atualize o README quando mudar módulos, variáveis de topo, ordem de aplicação ou premissas.
