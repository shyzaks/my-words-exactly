terraform {
  backend "s3" {
    bucket         = "my-words-exactly-tfstate-641884884481-us-east-2"
    key            = "dev/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "my-words-exactly-tf-locks"
    encrypt        = true
  }
}
