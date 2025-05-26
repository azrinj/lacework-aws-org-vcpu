# AWS Organization Inventory

This repository contains a bash script to count running EC2 instances and ECS Fargate resources across AWS accounts in an AWS Organization.

## Prerequisites

- AWS CLI
- jq

## AWS Requirements

### For the Management Account
- `organizations:ListAccounts` - To list all accounts in the organization
- `sts:AssumeRole` - To assume the OrganizationAccountAccessRole in member accounts
- `ec2:DescribeRegions` - To list all available AWS regions

### For Member Accounts
- `OrganizationAccountAccessRole` with the following permissions:
  - `ec2:DescribeInstances` - To list and describe EC2 instances
  - `ecs:ListClusters` - To list ECS clusters
  - `ecs:ListTasks` - To list ECS tasks in clusters
  - `ecs:DescribeTasks` - To get details about ECS tasks

### Region Configuration
- STS assume role capability must be enabled in each region you want to scan
- The script scans all available regions in each account by default

## Usage

1. Set the required environment variables:

```bash
export AWS_PROFILE=your-profile-name
export AWS_PAGER=""

# Optional: Set specific region for AWS Organizations API calls
# If not set, defaults to ap-southeast-1
export AWS_REGION=ap-southeast-1
```

2. Make the script executable (if not already):

```bash
chmod +x scripts/lacework-aws-org-vcpu.sh
```

3. Run the script:

```bash
cd scripts
./lacework-aws-org-vcpu.sh
```

## Example Output

```
Using AWS Profile: management-admin
Using AWS Region: ap-southeast-1 (for AWS Organizations API calls)

Retrieving accounts from AWS Organization...
Processing account: 194722123456
  EC2 instances in account 194722123456:
    t2.micro: 1
    t2.nano: 1
    Total EC2 instances: 2
    Total EC2 vCPUs: 2
  ECS Fargate in account 194722123456:
    No ECS clusters found
  Total vCPUs in account 194722123456: 2

Processing account: 534131123456
  EC2 instances in account 534131123456:
    No running EC2 instances found
  ECS Fargate in account 534131123456:
    ECS clusters: 1
    Running Fargate tasks: 1
    Fargate CPU units: 256
    Fargate vCPUs (CPU units / 1024): 0
  Total vCPUs in account 534131123456: 0

...

=============================================
ORGANIZATION-WIDE EC2 INSTANCE SUMMARY
=============================================
t2.micro: 10
t2.nano: 15
---------------------------------------------
TOTAL EC2 INSTANCES: 25
TOTAL EC2 vCPUs: 25

=============================================
ORGANIZATION-WIDE ECS FARGATE SUMMARY
=============================================
ECS clusters: 1
Running Fargate tasks: 1
Fargate CPU units: 1256
Fargate vCPUs (CPU units / 1024): 1

=============================================
ORGANIZATION-WIDE TOTAL vCPU SUMMARY
=============================================
EC2 vCPUs: 25
ECS Fargate vCPUs: 1
---------------------------------------------
TOTAL vCPUs: 26

Inventory complete.
```

