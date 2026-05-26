output "vpc_id" { value = aws_vpc.main.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "vpc_cidr" { value = aws_vpc.main.cidr_block }
output "vpc_endpoints_sg_id" { value = aws_security_group.vpc_endpoints.id }
