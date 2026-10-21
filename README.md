# AI Platform — plataforma mínima de agentes de IA (AWS, sa-east-1)

Este template Terraform cria a conta de workload **"AI Platform"** para o piloto: um **copiloto interno para operadores da central de atendimento**, com humano no loop e tools somente leitura (status de PIX, contestação e limites).

Princípios aplicados no código:

| Princípio | Como está garantido |
|---|---|
| Padronizar pontos de controle, não modelos | Todo LLM passa pelo **Amazon Bedrock** (allowlist + guardrail obrigatório por IAM). Toda tool passa pelo **AgentCore Gateway** (Policy Cedar). |
| O agente nunca tem mais permissão que o usuário | JWT do operador na entrada (Runtime e Gateway). Na saída para o core, há **token exchange** (RFC 8693) com escopo mínimo por tool. |
| Nada de tráfego de modelo pela internet | Subnets privadas e VPC endpoints (PrivateLink). Nenhuma rota `0.0.0.0/0 → IGW` nas subnets de workload. |
| Sem chaves estáticas | Não há usuário IAM nem access key (a SCP também nega). O client do token exchange usa `AWS_IAM_ID_TOKEN_JWT`. CI via OIDC. Não há LiteLLM nem gateway de terceiros. |
| Poucos serviços, gerenciados, tudo em IaC | Bedrock, AgentCore, OpenSearch Serverless, API Gateway, ALB/WAF e serviços nativos de segurança. |

---

## Diagrama

```
 Estações da central (rede corporativa / Direct Connect)
            │ HTTPS
            ▼
 ┌──────────────────────── Conta "AI Platform" — sa-east-1 ─────────────────────────┐
 │  VPC privada (2 AZs, sem IGW nas subnets de workload)                            │
 │                                                                                  │
 │  [WAF]──▶ ALB interno ── authenticate-oidc ──▶ IdP corporativo (Entra/Okta)      │
 │              │ (x-amzn-oidc-accesstoken)                                         │
 │              ▼                                                                   │
 │        BFF da central ──InvokeAgentRuntime (Bearer + Use-Case-Id)──┐             │
 │                                                       VPCE bedrock-agentcore     │
 │                                                                   ▼              │
 │   ┌───────────── AgentCore Runtime (1 por caso de uso, modo VPC) ─────────────┐  │
 │   │ role do caso ③ = só SEUS inference profiles + SEU guardrail               │  │
 │   └───────┬──────────────────────┬────────────────────────┬──────────────────┘  │
 │           │ ① VPCE bedrock-runtime│ ④ VPCE bedrock-agent-rt│ ② MCP (token user)  │
 │           ▼                      ▼                        ▼                     │
 │   Bedrock: app inference   Knowledge Base ──▶ OpenSearch   AgentCore Gateway    │
 │   profile + Guardrail      (S3 docs + metadata)  Serverless  JWT in · Cedar     │
 │   invocation logging                             (VPCE)     token exchange out  │
 │                                                                   │ Lattice      │
 │                                                                   ▼              │
 │                         VPCE execute-api ─▶ API Gateway REST PRIVADO (GET only)  │
 │                                                   │ VPC Link                     │
 │                                                   ▼                              │
 │                                             NLB interno ──TGW──▶ Direct Connect  │
 │                                                                   │              │
 │  ⑤ CloudWatch Logs (KMS) · X-Ray/ADOT · CloudTrail→S3 Object Lock · ▶ SIEM       │
 │  ⑥ S3 golden sets + role OIDC do pipeline · FinOps: Budgets/tag + CUR 2.0        │
 │  Baseline: KMS (logs/data/kb) · Config · GuardDuty · Macie                        │
 │  Egress externo: só se allowlist ≠ ∅ → Network Firewall → NAT → IGW               │
 └──────────────────────────────────────────────────────────────────────────────────┘
                                                                     ▼
                                                    APIs do core (data center do banco)
 Conta de gerenciamento: SCPs (stacks/org-guardrails)
```

## Mapeamento componente → módulo

| Componente | Módulo | Principais recursos |
|---|---|---|
| Entrada (ALB + WAF) | `modules/ingress` | `aws_lb` interno, listener HTTPS `authenticate-oidc`, `aws_wafv2_web_acl` (managed rules + rate limit) |
| Agente | `modules/agent-runtime` | `aws_bedrockagentcore_agent_runtime` (VPC, JWT), endpoint, ECR, `aws_bedrockagentcore_workload_identity`, log delivery (logs + traces) |
| ① LLM Gateway | `modules/llm-gateway` | `aws_bedrock_guardrail` + `_version` por caso, `aws_bedrock_model_invocation_logging_configuration` (S3 + CWL) |
| ② Tool Gateway (MCP) | `modules/tool-gateway` | `aws_bedrockagentcore_gateway` (CUSTOM_JWT, MCP), `_gateway_target` (OpenAPI + OAuth `TOKEN_EXCHANGE` + `private_endpoint`), `_oauth2_credential_provider`, `_policy_engine` + `_policy` (Cedar), API Gateway privado + VPC Link/NLB |
| ③ Registro de casos de uso | `modules/use-case` + variável `use_cases` | `aws_bedrock_inference_profile` (por modelo do caso), role de menor privilégio, policy de bloqueio |
| ④ Conhecimento (RAG) | `modules/knowledge-base` | bucket de documentos, coleção AOSS `VECTORSEARCH` + políticas, índice (`awscc`), `aws_bedrockagent_knowledge_base` + data source |
| ⑤ Observabilidade | `modules/observability` (+ log groups em cada módulo) | CloudTrail com Object Lock, X-Ray Transaction Search, subscription filters → SIEM, bucket de access logs |
| ⑥ Avaliação | `modules/evaluation` | bucket de golden sets, role do pipeline via OIDC |
| Rede | `modules/network` | VPC, subnets, VPC endpoints, S3 gateway endpoint, TGW, Network Firewall (condicional), Flow Logs |
| KMS | `modules/kms` | CMKs `logs`, `data` e `kb`, com rotação e key policies explícitas |
| Baseline | `modules/security-baseline` | AWS Config + regras, GuardDuty, Macie (job no bucket de documentos) |
| FinOps | `modules/finops` | `aws_budgets_budget` por caso (80% alerta) + `aws_budgets_budget_action` (100%), `aws_bcmdataexports_export` (CUR 2.0) |
| SCPs | `modules/org-guardrails` via `stacks/org-guardrails` | 2 SCPs: região + allowlist de modelos; logging + IAM users/keys |
| (apoio) | `modules/s3-secure-bucket` | Bucket padrão: KMS, versionamento, PAB, TLS obrigatório, Object Lock opcional |

**Providers.** O `hashicorp/aws ~> 6.69` cobre todo o AgentCore de forma nativa. O `hashicorp/awscc ~> 1.106` é usado apenas no índice vetorial (`awscc_opensearchserverless_collection_index`), que o `aws` não tem.

## Estrutura

```
modules/      network kms llm-gateway tool-gateway agent-runtime knowledge-base use-case
              observability finops ingress security-baseline evaluation s3-secure-bucket
              org-guardrails (só para o stack da organização)
envs/dev      main.tf variables.tf outputs.tf providers.tf versions.tf backend.tf terraform.tfvars.example
envs/prd      idem (com preconditions extras de produção)
stacks/org-guardrails   SCPs — aplicado na conta de gerenciamento
specs/openapi           pix-status, contestacao, limites (templates com a URL do API privado)
.github/workflows/terraform.yml   fmt · validate · tflint · checkov · plan
```

## Pré-requisitos

1. **Organizations.** A conta "AI Platform" (dev e prd) precisa existir, numa OU de workloads de IA.
2. **State.** Um bucket S3 de state com versionamento e CMK, na conta de deployments ou de gerenciamento. O lock é nativo (`use_lockfile`), sem DynamoDB.
3. **Roles de deploy assumidas por OIDC.** Uma role de *plan* (somente leitura) e uma de *apply* por conta, além de `vars` no GitHub: `AWS_PLAN_ROLE_ARN`, `TF_STATE_BUCKET`, `TF_STATE_KMS_KEY_ARN` e `TFVARS`. O OIDC provider do CI precisa existir na conta (é usado por `ci_oidc_provider_arn`).
4. **Bedrock em sa-east-1.** Habilite o acesso aos modelos da allowlist (incluindo o de embeddings) e confirme quais IDs existem *in-region*.
5. **Rede.**
   - CIDR /16 sem sobreposição com o data center.
   - TGW compartilhado via RAM, com rota para o Direct Connect.
   - IPs e hostname TLS das APIs do core.
   - Certificado ACM para o ALB.
6. **IdP (Entra ID ou Okta).**
   - App da central, com client secret guardado no **Secrets Manager** (`alb_oidc_client_secret_arn`).
   - Audience da API da plataforma.
   - Escopos `pix.status.read`, `contestacao.read` e `limites.read`.
   - Client de token exchange que confia no **issuer de outbound identity federation da conta** (output `outbound_identity_issuer`, disponível após o 1º apply).
7. **FinOps.** Ative `use_case` (e as demais tags obrigatórias) como **cost allocation tags** no Billing da conta de gerenciamento.
8. **Serviços já centralizados.** Se Config, GuardDuty, Macie ou a role de CloudWatch do API Gateway já forem geridos pela organização, desligue os toggles `enable_*` e `manage_apigw_account_settings`.

## Ordem de aplicação

```
1. stacks/org-guardrails     (conta de gerenciamento)
2. envs/<env>  -target=module.kms -target=module.network
3. envs/<env>  apply completo
4. Pós-apply: cadastrar outbound_identity_issuer no IdP; publicar a imagem do agente no ECR
   (output agent_ecr_repositories) com a tag de use_cases.*.container_image_tag; subir
   documentos + .metadata.json no bucket da KB e disparar o sync do data source.
```

Comandos:

```bash
cd stacks/org-guardrails
terraform init -backend-config="bucket=<state>" -backend-config="kms_key_id=<cmk>"
terraform apply -var-file=terraform.tfvars

cd ../../envs/dev
cp terraform.tfvars.example terraform.tfvars   # ajuste os valores
terraform init -backend-config="bucket=<state>" -backend-config="kms_key_id=<cmk>"
terraform apply -target=module.kms -target=module.network
terraform apply
```

> A imagem do agente precisa existir no ECR antes de o Runtime ser criado. No 1º apply de um ambiente novo, aplique antes `-target='module.agent_runtime["copiloto-central"].aws_ecr_repository.this'`, publique a imagem e rode o apply completo.

## Registro de casos de uso (③)

O caso de uso entra no mapa `use_cases` (ver `terraform.tfvars.example`, com o caso `copiloto-central` preenchido). **Sem entrada no mapa, sem acesso.** Para cada entrada, o Terraform cria:

- uma *application inference profile* por modelo permitido, com as tags do caso (custo) e cópia do modelo **in-region**;
- uma role cuja policy:
  - permite `InvokeModel*` **só** nos profiles do caso;
  - permite o modelo de base **só** quando a chamada chega por esses profiles (`bedrock:InferenceProfileArn`);
  - **nega** qualquer invocação sem o guardrail e a versão do caso (`bedrock:GuardrailIdentifier`);
  - permite `ApplyGuardrail` só no guardrail do caso e `Retrieve` só na KB;
- um guardrail próprio (versão publicada), um AgentCore Runtime, um budget e uma budget action.

O plan falha se o caso pedir um modelo fora de `allowed_model_ids` ou uma tool fora de `tools`.

**Verificação do critério de aceite:** o output `use_case_role_policies` traz a policy gerada por caso.

## Tools (②)

O catálogo `tools` registra cada tool com `effect = "read" | "write"`, escopos OAuth e as operações (operationId) expostas.

- **Leitura:** recebe uma policy Cedar de *permit* (exige o escopo no token).
- **Com efeito (`write`):** fica registrada, mas não recebe permit (é negada). Além disso, o módulo recusa o plan enquanto `allow_write_tools = false`.
- **Modo da policy:** `LOG_ONLY` em dev e `ENFORCE` em prd.
- **Inventário:** veja o output `tool_catalog`.

## Avaliação (⑥) — onde o CI se conecta

O pipeline (fora do escopo) segue estes passos:

1. Assume `evaluation_pipeline_role_arn` via OIDC.
2. Lê `s3://<evaluation_bucket>/golden-sets/<caso>/`.
3. Chama `InvokeAgentRuntime` no runtime do caso com tokens de teste.
4. Grava em `results/<caso>/<run>/` e bloqueia a promoção dev → prd abaixo do limiar.

## Qualidade

| Ferramenta | Arquivo | Resultado nesta entrega |
|---|---|---|
| `terraform fmt` | — | Sem diferenças (checado com OpenTofu 1.13 `fmt`). |
| `tflint` 0.64 + ruleset aws 0.49 | `.tflint.hcl` | 0 issues em todos os módulos e ambientes. |
| `checkov` 3.3.30 | `.checkov.yaml` | 0 falhas. Cada exceção é um `#checkov:skip` justificado no recurso. |
| `terraform validate` / `plan` | workflow | Rodam no CI; ver TODO 1. |

## Premissas e TODOs

**Bloqueantes (validar antes do 1º apply)**

1. **`init/validate/plan` não foram executados.** O registry do Terraform estava inacessível no ambiente de geração. Em compensação:
   - todos os 103 tipos de recurso e data source, e cada argumento ou bloco usado, foram conferidos contra a documentação oficial do `aws` v6.69.1 e do `awscc` v1.106.0;
   - as interfaces entre módulos foram checadas por script.

   Rode o workflow antes do 1º apply.
2. **Disponibilidade em sa-east-1.** Confirmar AgentCore (Runtime, Gateway, Identity e Policy), os VPC endpoints listados (inclusive `bedrock-agentcore`) e cada modelo da allowlist *in-region*. Se algo só existir fora da região, a decisão sobre residência de dados é do banco. Perfis `us.`/`global.` são bloqueados por validação e pela SCP.
3. **Cedar do Policy in AgentCore** (`modules/tool-gateway/targets.tf`). Validar:
   - o esquema de entidades (`AgentCore::OAuthUser`, `AgentCore::Action::"<target>___<op>"`, `AgentCore::Gateway`);
   - o claim de escopo (`scope` ou `scp`).

   Com `FAIL_ON_ANY_FINDINGS`, um erro de sintaxe aparece no apply.
4. **Ações IAM do policy engine** na role do gateway (`bedrock-agentcore:AuthorizeAction` e afins), em `modules/tool-gateway/main.tf`.
5. **Formato de `index_schema`** do `awscc_opensearchserverless_collection_index`. Se não funcionar, crie o índice por um runner dentro da VPC.

**Decisões e alternativas documentadas**

6. **mTLS no API Gateway privado.** Não há mTLS de entrada em endpoint `PRIVATE`. A alternativa é a resource policy restrita ao VPCE, somada ao token do operador validado no core e a um *client certificate* do API Gateway para o backend (mTLS de saída). Validar o client certificate com VPC Link + NLB em TCP passthrough; senão, terminar o TLS num proxy do lado do core.
7. **Client secret do ALB.** O `authenticate-oidc` exige o client secret do IdP. Ele vem do Secrets Manager e fica no state (criptografado). É a única credencial estática da solução e não é uma chave AWS nem de provedor de modelo.
8. **Egress.** Com `egress_allowed_domains = []` não existe caminho para a internet. Os nós do ALB precisam alcançar o token endpoint do IdP:
   - IdP SaaS: inclua só os domínios do IdP na allowlist e ligue `alb_idp_egress_via_firewall`;
   - IdP alcançável por rota privada: use `alb_idp_egress_cidrs`.
9. **Grant do token exchange.** Okta implementa RFC 8693 (`TOKEN_EXCHANGE`). No Entra ID, o equivalente é o *on-behalf-of* (`JWT_AUTHORIZATION_GRANT`); ajuste `token_exchange_grant_type` e `idp_scope_claim_name = "scp"`.
10. **BFF da central.** O target group do ALB espera o BFF da aplicação (IPs por variável). O BFF repassa o `x-amzn-oidc-accesstoken` como `Authorization: Bearer` e envia `X-Amzn-Bedrock-AgentCore-Runtime-Custom-Use-Case-Id`.
11. **Filtro de permissão na KB.** Cada documento tem um sidecar `.metadata.json` com `allowed_groups`, `source_system` e `classification`. O agente **sempre** aplica o filtro com os grupos do token do operador. Essa obrigação fica no código do agente, então vale cobri-la com teste no golden set.
12. **CUR 2.0 e Budgets.** São serviços globais (plano de controle em us-east-1); o dado do CUR é entregue no bucket em sa-east-1. Se o banco centraliza o CUR na conta de gerenciamento, use `enable_cur_export = false`.
13. **Recursos singleton de conta.** São eles: outbound identity federation, `aws_api_gateway_account`, Config recorder, GuardDuty e Macie. Desligue o toggle correspondente se já existirem.
14. **Guardrail.** CPF, CNPJ, agência/conta e chave PIX aleatória são mascarados por regex próprias, porque não há tipo nativo para elas. Calibre as regex com amostras reais para evitar falso positivo, por exemplo números de protocolo.
