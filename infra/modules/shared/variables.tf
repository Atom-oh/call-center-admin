variable "env" {
  type        = string
  description = "dev | stg | prd"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}
