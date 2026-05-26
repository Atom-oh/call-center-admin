output "firehose_name" { value = aws_kinesis_firehose_delivery_stream.consult.name }
output "firehose_arn" { value = aws_kinesis_firehose_delivery_stream.consult.arn }
output "glue_db_name" { value = aws_glue_catalog_database.main.name }
output "glue_table_name" { value = aws_glue_catalog_table.consult_results.name }
output "athena_workgroup" { value = aws_athena_workgroup.main.name }
