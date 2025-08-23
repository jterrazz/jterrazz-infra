# Terraform Remote State Backend Configuration
# Stores state in cloud for persistence across GitHub Actions runs

terraform {
  # Option 1: Terraform Cloud (Recommended - Free for small teams)
  cloud {
    organization = "your-organization"  # Replace with your org name
    
    workspaces {
      name = "jterrazz-infra-production"
    }
  }
  
  # Option 2: S3-compatible backend (if you prefer self-hosted)
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "jterrazz-infra/terraform.tfstate"
  #   region = "eu-central-1"
  #   
  #   # For S3-compatible storage like Backblaze B2 or DigitalOcean Spaces
  #   endpoint = "https://s3.eu-central-003.backblazeb2.com"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check = true
  #   skip_region_validation = true
  #   force_path_style = true
  # }
  
  # Option 3: HTTP backend (for GitLab/GitHub packages, etc.)
  # backend "http" {
  #   address = "https://gitlab.com/api/v4/projects/PROJECT_ID/terraform/state/production"
  #   lock_address = "https://gitlab.com/api/v4/projects/PROJECT_ID/terraform/state/production/lock"
  #   unlock_address = "https://gitlab.com/api/v4/projects/PROJECT_ID/terraform/state/production/lock"
  #   username = "your-username"
  #   password = "your-access-token"
  # }
}
