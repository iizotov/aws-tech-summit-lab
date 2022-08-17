#!/bin/bash

MAINREGION=us-east-1
SECONDARYREGION=ap-southeast-2

wget https://raw.githubusercontent.com/iizotov/aws-tech-summit-lab/main/main.cform
wget https://raw.githubusercontent.com/iizotov/aws-tech-summit-lab/main/secondary.cform

aws cloudformation deploy \
    --region $MAINREGION \
    --template-file ./main.cform --stack-name lab-$MAINREGION \
    --capabilities CAPABILITY_IAM \
    --no-cli-pager


# establish EFS replication
EFSID=$(aws efs describe-file-systems \
    --region $MAINREGION \
    --max-items 1 \
    --query FileSystems[].FileSystemId \
    --output text)
    
SECONDARYEFSID=$(aws efs create-replication-configuration \
    --region $MAINREGION \
    --source-file-system-id $EFSID \
    --destinations Region=$SECONDARYREGION \
    --no-cli-pager \
    --query Destinations[0].FileSystemId \
    --output text)

SECONDARYEFSID=$(aws efs describe-file-systems \
    --region $SECONDARYREGION \
    --max-items 1 \
    --query FileSystems[].FileSystemId \
    --output text \
    --no-cli-pager)

# deploy second region
aws cloudformation deploy \
    --region $SECONDARYREGION \
    --template-file ./secondary.cform --stack-name lab-$SECONDARYREGION \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides EFSFileSystem=$SECONDARYEFSID \
    --no-cli-pager

# establish write forwarding
aws rds modify-db-cluster \
    --db-cluster-identifier secondary-aurora-cluster \
    --region $SECONDARYREGION \
    --enable-global-write-forwarding \
    --no-cli-pager

#scale out wordpress in secondary region
aws ecs update-service \
    --region $SECONDARYREGION \
    --cluster wordpress-ecs-cluster \
    --service wordpress-service \
    --desired-count 3 \
    --no-cli-pager

#get a task id in primary region
ECSTASK=$(aws ecs list-tasks \
    --region $MAINREGION \
    --cluster wordpress-ecs-cluster \
    --output text \
    --query taskArns[0] \
    --service-name wordpress-service)

#update wordpress settings
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "session-manager-plugin.rpm"
sudo yum install -y session-manager-plugin.rpm
aws ecs execute-command \
    --cluster wordpress-ecs-cluster \
	--region $MAINREGION \
    --task $ECSTASK \
    --container wordpress-container \
	--interactive \
    --command "wp --allow-root option update comment_previously_approved 0"

aws ecs execute-command \
    --cluster wordpress-ecs-cluster \
	--region $MAINREGION \
    --task $ECSTASK \
    --container wordpress-container \
	--interactive \
    --command "wp --allow-root option update require_name_email 0"

aws ecs execute-command \
    --cluster wordpress-ecs-cluster \
	--region $MAINREGION \
    --task $ECSTASK \
    --container wordpress-container \
	--interactive \
    --command "wp --allow-root post create --post_title='Welcome to Tech Summit 2022' --post_content 'Try creating comments here and see how it propagates to another region'"

aws ecs execute-command \
    --cluster wordpress-ecs-cluster \
	--region $MAINREGION \
    --task $ECSTASK \
    --container wordpress-container \
	--interactive \
    --command "wp --allow-root post delete 1 --force"

#scale out wordpress in main region
aws ecs update-service \
    --region $MAINREGION \
    --cluster wordpress-ecs-cluster \
    --service wordpress-service \
    --desired-count 3 \
    --no-cli-pager




