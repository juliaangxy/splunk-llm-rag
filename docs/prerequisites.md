# Prerequisites

- AWS account with permissions for CloudFormation, EC2, IAM, VPC, and S3
- Splunk Enterprise rpm downloaded using SplunkBase and license files (if any)
- AWS CLI configured for local deployment
- Existing EC2 key pair
- Target AWS region selected by user at deploy time (for example, us-east-1)
- jq installed locally for parameter processing
- Python 3 and pip installed locally (used by Hugging Face model upload helpers)
- Ansible installed locally for post-deploy app installation workflow
- Explicit SSH CIDR prepared by user (to configure for remote connection into the EC2 instance)
- Docker, Brew and AWS CLI installed on the machine from which you run the scripts
- If provisioning shared infrastructure, a user-controlled resource name prefix that can be used as the base for S3 bucket and ECR repository names; if shared infrastructure is skipped, this prefix is not needed

## NVIDIA DLAMI lookup

The deployment uses AWS public SSM parameters to resolve the latest NVIDIA DLAMI
for x86 GPU PyTorch 2.9 on Amazon Linux 2023 in your chosen region.

Manual lookup example:

```bash
./utils/get-dlami-ami-id.sh us-east-1
```
