variable "env" {
  type    = string
  default = "dev"
}

# Atlantis 가 cross-account assume_role 로 리소스를 다루도록 하는 옵션.
# 기본값: <AWS_ACCOUNT_ALIAS> 계정 (<ACCOUNT_ID>) 의 <TERRAFORMER_ROLE>.
# 로컬 또는 다른 환경 (CI OIDC 등) 에서 직접 IAM 자격을 쓸 때는 빈 문자열로 override.
variable "terraformer_role_arn" {
  type        = string
  default     = "arn:aws:iam::<ACCOUNT_ID>:role/<TERRAFORMER_ROLE>"
  description = "AssumeRole target for the AWS provider. Empty string disables the assume_role block."
}
