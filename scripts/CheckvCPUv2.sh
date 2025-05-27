#!/bin/bash
# Script to count running EC2 instances by instance type and ECS Fargate vCPUs across an AWS organization
# Outputs counts per account, and then for the entire organization

# Don't exit on error, we'll handle errors manually
set +e

# Create temporary files for storing instance counts
ORG_EC2_COUNTS_FILE=$(mktemp)
ORG_ECS_COUNTS_FILE=$(mktemp)

# Check for required tools
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq first."
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is required but not installed. Please install AWS CLI first."
    exit 1
fi

# Check for required environment variables
if [ -z "$AWS_PROFILE" ]; then
    echo "Error: AWS_PROFILE environment variable is not set."
    exit 1
fi

# Set default region if not provided
if [ -z "$AWS_REGION" ]; then
    AWS_REGION="ap-southeast-1"  # Default to ap-southeast-1 if not specified
    echo "AWS_REGION not set, defaulting to: $AWS_REGION"
fi

echo "Using AWS Profile: $AWS_PROFILE"
echo "Using AWS Region: $AWS_REGION (for AWS Organizations API calls)"
echo

# Get all accounts in the organization (use profile)
ACCOUNTS=$(aws organizations list-accounts --query "Accounts[?Status=='ACTIVE'].Id" --output text --profile "$AWS_PROFILE")

# Unset AWS_PROFILE after org-level calls
unset AWS_PROFILE

if [ -z "$ACCOUNTS" ]; then
    echo "Error: No active accounts found in the organization."
    exit 1
fi

# Initialize organization-wide counters
ORG_TOTAL_EC2=0
ORG_TOTAL_EC2_VCPU=0
ORG_TOTAL_ECS_CLUSTERS=0
ORG_TOTAL_ECS_TASKS=0
ORG_TOTAL_ECS_CPU_UNITS=0
ORG_TOTAL_ECS_VCPU=0

# Process each account
for ACCOUNT_ID in $ACCOUNTS; do
    echo "============================================="
    echo "Processing account: $ACCOUNT_ID"
    echo "============================================="

    # Clear any existing temporary credentials
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN

    # Set the role ARN
    ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/<edityourRoleHere>"
    echo "Attempting to assume role: $ROLE_ARN"

    # Use your SSO profile for assume-role
    CREDENTIALS=$(aws sts assume-role \
        --role-arn "$ROLE_ARN" \
        --role-session-name "EC2ECSInventorySession" \
        --query "Credentials" \
        --output json --profile masteradmin 2> >(tee /tmp/error.txt >&2))

    if [ $? -ne 0 ]; then
        echo "Warning: Could not assume role in $ACCOUNT_ID (permission denied or role doesn't exist), skipping..."
        echo
        continue
    fi

    # Save credentials to file for debugging
    echo "$CREDENTIALS" > /tmp/credentials.json

    # Read and export credentials
    export AWS_ACCESS_KEY_ID=$(jq -r '.AccessKeyId' /tmp/credentials.json)
    export AWS_SECRET_ACCESS_KEY=$(jq -r '.SecretAccessKey' /tmp/credentials.json)
    export AWS_SESSION_TOKEN=$(jq -r '.SessionToken' /tmp/credentials.json)

    # Unset AWS_PROFILE to ensure only env vars are used
    unset AWS_PROFILE

    # Create temporary file for account-specific counters
    ACCOUNT_EC2_COUNTS_FILE=$(mktemp)
    
    # Initialize account-specific counters
    ACCOUNT_TOTAL_EC2=0
    ACCOUNT_TOTAL_EC2_VCPU=0
    ACCOUNT_TOTAL_ECS_CLUSTERS=0
    ACCOUNT_TOTAL_ECS_TASKS=0
    ACCOUNT_TOTAL_ECS_CPU_UNITS=0
    
    # Get all regions
    REGIONS=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text)
    
    # Process each region
    for REGION in $REGIONS; do
        # Get running EC2 instances in the region
        INSTANCES=$(aws ec2 describe-instances \
            --region "$REGION" \
            --filters "Name=instance-state-name,Values=running" \
            --query "Reservations[].Instances[].[InstanceType, CpuOptions.CoreCount, CpuOptions.ThreadsPerCore]" \
            --output json 2>/dev/null || echo "[]")
        
        if [ "$INSTANCES" != "[]" ]; then
            # Save instance data to a temporary file to avoid subshell variable scope issues
            TEMP_INSTANCES_FILE=$(mktemp)
            echo "$INSTANCES" | jq -c '.[]' 2>/dev/null > "$TEMP_INSTANCES_FILE"
            
            # Process each instance
            while read -r INSTANCE; do
                INSTANCE_TYPE=$(echo $INSTANCE | jq -r '.[0]')
                CORES=$(echo $INSTANCE | jq -r '.[1]')
                THREADS=$(echo $INSTANCE | jq -r '.[2]')
                VCPUS=$((CORES * THREADS))
                
                # Update EC2 instance count for this type
                COUNT=$(grep -c "^$INSTANCE_TYPE\t" "$ACCOUNT_EC2_COUNTS_FILE" 2>/dev/null)
                if [ $COUNT -gt 0 ]; then
                    # Get current count
                    CURRENT=$(grep "^$INSTANCE_TYPE\t" "$ACCOUNT_EC2_COUNTS_FILE" | cut -f2)
                    # Increment count
                    NEW_COUNT=$((CURRENT + 1))
                    # Create new file without the line
                    grep -v "^$INSTANCE_TYPE\t" "$ACCOUNT_EC2_COUNTS_FILE" > "${ACCOUNT_EC2_COUNTS_FILE}.new"
                    # Add updated line
                    echo -e "$INSTANCE_TYPE\t$NEW_COUNT" >> "${ACCOUNT_EC2_COUNTS_FILE}.new"
                    # Replace old file
                    mv "${ACCOUNT_EC2_COUNTS_FILE}.new" "$ACCOUNT_EC2_COUNTS_FILE"
                else
                    # Add new instance type
                    echo -e "$INSTANCE_TYPE\t1" >> "$ACCOUNT_EC2_COUNTS_FILE"
                fi
                
                # Update organization-wide EC2 counts
                COUNT=$(grep -c "^$INSTANCE_TYPE\t" "$ORG_EC2_COUNTS_FILE" 2>/dev/null)
                if [ $COUNT -gt 0 ]; then
                    # Get current count
                    CURRENT=$(grep "^$INSTANCE_TYPE\t" "$ORG_EC2_COUNTS_FILE" | cut -f2)
                    # Increment count
                    NEW_COUNT=$((CURRENT + 1))
                    # Create new file without the line
                    grep -v "^$INSTANCE_TYPE\t" "$ORG_EC2_COUNTS_FILE" > "${ORG_EC2_COUNTS_FILE}.new"
                    # Add updated line
                    echo -e "$INSTANCE_TYPE\t$NEW_COUNT" >> "${ORG_EC2_COUNTS_FILE}.new"
                    # Replace old file
                    mv "${ORG_EC2_COUNTS_FILE}.new" "$ORG_EC2_COUNTS_FILE"
                else
                    # Add new instance type
                    echo -e "$INSTANCE_TYPE\t1" >> "$ORG_EC2_COUNTS_FILE"
                fi
                
                # Update EC2 instance and vCPU totals
                ACCOUNT_TOTAL_EC2=$((ACCOUNT_TOTAL_EC2 + 1))
                ACCOUNT_TOTAL_EC2_VCPU=$((ACCOUNT_TOTAL_EC2_VCPU + VCPUS))
                ORG_TOTAL_EC2=$((ORG_TOTAL_EC2 + 1))
                ORG_TOTAL_EC2_VCPU=$((ORG_TOTAL_EC2_VCPU + VCPUS))
            done < "$TEMP_INSTANCES_FILE"
            
            # Clean up temporary file
            rm -f "$TEMP_INSTANCES_FILE"
        fi
        
        # Get ECS Fargate clusters in the region
        ECS_CLUSTERS=$(aws ecs list-clusters \
            --region "$REGION" \
            --output json 2>/dev/null | jq -r '.clusterArns[]' 2>/dev/null || echo "")
        
        # Count ECS clusters
        CLUSTER_COUNT=$(echo "$ECS_CLUSTERS" | grep -c "^arn:" || echo "0")
        # Ensure CLUSTER_COUNT is a number
        if [[ "$CLUSTER_COUNT" =~ ^[0-9]+$ ]]; then
            ACCOUNT_TOTAL_ECS_CLUSTERS=$((ACCOUNT_TOTAL_ECS_CLUSTERS + CLUSTER_COUNT))
            ORG_TOTAL_ECS_CLUSTERS=$((ORG_TOTAL_ECS_CLUSTERS + CLUSTER_COUNT))
        fi
        
        # Process each ECS cluster for Fargate tasks
        for CLUSTER in $ECS_CLUSTERS; do
            # Get all tasks in the cluster
            TASKS=$(aws ecs list-tasks \
                --region "$REGION" \
                --cluster "$CLUSTER" \
                --output json 2>/dev/null | jq -r '.taskArns[]' 2>/dev/null || echo "")
            
            # Save tasks to a temporary file to avoid subshell variable scope issues
            if [ -n "$TASKS" ]; then
                TEMP_TASKS_FILE=$(mktemp)
                echo "$TASKS" > "$TEMP_TASKS_FILE"
                
                # Process each task
                while read -r TASK_ARN; do
                    if [ -n "$TASK_ARN" ]; then
                        # Get Fargate task details
                        TASK_DETAILS=$(aws ecs describe-tasks \
                            --region "$REGION" \
                            --cluster "$CLUSTER" \
                            --tasks "$TASK_ARN" \
                            --output json 2>/dev/null)
                        
                        # Check if it's a running Fargate task
                        LAUNCH_TYPE=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].launchType' 2>/dev/null)
                        TASK_STATUS=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].lastStatus' 2>/dev/null)
                        
                        if [ "$LAUNCH_TYPE" = "FARGATE" ] && [ "$TASK_STATUS" = "RUNNING" ]; then
                            # Increment task count
                            ACCOUNT_TOTAL_ECS_TASKS=$((ACCOUNT_TOTAL_ECS_TASKS + 1))
                            ORG_TOTAL_ECS_TASKS=$((ORG_TOTAL_ECS_TASKS + 1))
                            
                            # Get CPU units
                            CPU_VALUE=$(echo "$TASK_DETAILS" | jq -r '.tasks[0].cpu' 2>/dev/null)
                            if [[ "$CPU_VALUE" =~ ^[0-9]+$ ]]; then
                                ACCOUNT_TOTAL_ECS_CPU_UNITS=$((ACCOUNT_TOTAL_ECS_CPU_UNITS + CPU_VALUE))
                                ORG_TOTAL_ECS_CPU_UNITS=$((ORG_TOTAL_ECS_CPU_UNITS + CPU_VALUE))
                            fi
                        fi
                    fi
                done < "$TEMP_TASKS_FILE"
                
                # Clean up temporary file
                rm -f "$TEMP_TASKS_FILE"
            fi
        done
    done
    
    # Calculate ECS Fargate vCPUs (CPU units / 1024)
    if [[ $ACCOUNT_TOTAL_ECS_CPU_UNITS -gt 0 ]]; then
        ACCOUNT_TOTAL_ECS_VCPU=$((ACCOUNT_TOTAL_ECS_CPU_UNITS / 1024))
    else
        ACCOUNT_TOTAL_ECS_VCPU=0
    fi
    
    # Output account summary
    echo "  EC2 instances in account $ACCOUNT_ID:"
    if [ ! -s "$ACCOUNT_EC2_COUNTS_FILE" ]; then
        echo "    No running EC2 instances found"
    else
        # Create a temporary file to store the sorted output
        TEMP_SORTED_FILE=$(mktemp)
        sort "$ACCOUNT_EC2_COUNTS_FILE" > "$TEMP_SORTED_FILE"
        
        # Display instance types and counts
        while IFS="	" read -r INSTANCE_TYPE COUNT; do
            echo "    $INSTANCE_TYPE: $COUNT"
        done < "$TEMP_SORTED_FILE"
        
        # Clean up temporary file
        rm -f "$TEMP_SORTED_FILE"
        
        echo "    Total EC2 instances: $ACCOUNT_TOTAL_EC2"
        echo "    Total EC2 vCPUs: $ACCOUNT_TOTAL_EC2_VCPU"
    fi
    
    echo "  ECS Fargate in account $ACCOUNT_ID:"
    if [ $ACCOUNT_TOTAL_ECS_CLUSTERS -eq 0 ]; then
        echo "    No ECS clusters found"
    else
        echo "    ECS clusters: $ACCOUNT_TOTAL_ECS_CLUSTERS"
        echo "    Running Fargate tasks: $ACCOUNT_TOTAL_ECS_TASKS"
        echo "    Fargate CPU units: $ACCOUNT_TOTAL_ECS_CPU_UNITS"
        echo "    Fargate vCPUs (CPU units / 1024): $ACCOUNT_TOTAL_ECS_VCPU"
    fi
    
    echo "  Total vCPUs in account $ACCOUNT_ID: $((ACCOUNT_TOTAL_EC2_VCPU + ACCOUNT_TOTAL_ECS_VCPU))"
    echo
    
    # Clean up account counts file
    rm -f "$ACCOUNT_EC2_COUNTS_FILE"

    # Clean up temporary files
    rm -f /tmp/credentials.json /tmp/error.txt

    # Clear credentials
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
done

# Calculate organization-wide ECS Fargate vCPUs
if [[ $ORG_TOTAL_ECS_CPU_UNITS -gt 0 ]]; then
    ORG_TOTAL_ECS_VCPU=$((ORG_TOTAL_ECS_CPU_UNITS / 1024))
else
    ORG_TOTAL_ECS_VCPU=0
fi

# Output organization-wide EC2 summary
echo "=============================================" 
echo "ORGANIZATION-WIDE EC2 INSTANCE SUMMARY"
echo "=============================================" 
if [ ! -s "$ORG_EC2_COUNTS_FILE" ]; then
    echo "No running EC2 instances found across the organization"
else
    # Create a temporary file to store the sorted output
    TEMP_SORTED_FILE=$(mktemp)
    sort "$ORG_EC2_COUNTS_FILE" > "$TEMP_SORTED_FILE"
    
    # Display instance types and counts
    while IFS="	" read -r INSTANCE_TYPE COUNT; do
        echo "$INSTANCE_TYPE: $COUNT"
    done < "$TEMP_SORTED_FILE"
    
    # Clean up temporary file
    rm -f "$TEMP_SORTED_FILE"
    
    echo "---------------------------------------------"
    echo "TOTAL EC2 INSTANCES: $ORG_TOTAL_EC2"
    echo "TOTAL EC2 vCPUs: $ORG_TOTAL_EC2_VCPU"
fi

# Output organization-wide ECS summary
echo
echo "=============================================" 
echo "ORGANIZATION-WIDE ECS FARGATE SUMMARY"
echo "=============================================" 
if [ $ORG_TOTAL_ECS_CLUSTERS -eq 0 ]; then
    echo "No ECS Fargate clusters found across the organization"
else
    echo "ECS clusters: $ORG_TOTAL_ECS_CLUSTERS"
    echo "Running Fargate tasks: $ORG_TOTAL_ECS_TASKS"
    echo "Fargate CPU units: $ORG_TOTAL_ECS_CPU_UNITS"
    echo "Fargate vCPUs: $ORG_TOTAL_ECS_VCPU"
fi

# Output organization-wide total vCPUs
echo
echo "=============================================" 
echo "ORGANIZATION-WIDE TOTAL vCPU SUMMARY"
echo "=============================================" 
echo "EC2 vCPUs: $ORG_TOTAL_EC2_VCPU"
echo "ECS Fargate vCPUs: $ORG_TOTAL_ECS_VCPU"
echo "---------------------------------------------"
echo "TOTAL vCPUs: $((ORG_TOTAL_EC2_VCPU + ORG_TOTAL_ECS_VCPU))"

# Clean up organization counts file
rm -f "$ORG_EC2_COUNTS_FILE"

# Restore original environment
echo
echo "Inventory complete."