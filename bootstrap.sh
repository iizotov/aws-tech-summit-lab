#!/bin/bash

export MAINREGION=us-east-1
export SECONDARYREGION=ap-southeast-2

wget https://raw.githubusercontent.com/iizotov/aws-tech-summit-lab/main/main.cform
wget https://raw.githubusercontent.com/iizotov/aws-tech-summit-lab/main/secondary.cform

/usr/local/bin/aws cloudformation deploy \
    --region $MAINREGION \
    --template-file ./main.cform \
    --stack-name lab-$MAINREGION \
    --capabilities CAPABILITY_IAM \
    --no-cli-pager

# establish EFS replication
export EFSID=$(/usr/local/bin/aws efs describe-file-systems \
    --region $MAINREGION \
    --max-items 1 \
    --query FileSystems[].FileSystemId \
    --output text)
    
export SECONDARYEFSID=$(/usr/local/bin/aws efs create-replication-configuration \
    --region $MAINREGION \
    --source-file-system-id $EFSID \
    --destinations Region=$SECONDARYREGION \
    --no-cli-pager \
    --query Destinations[0].FileSystemId \
    --output text)

export SECONDARYEFSID=$(/usr/local/bin/aws efs describe-file-systems \
    --region $SECONDARYREGION \
    --query FileSystems[0].FileSystemId \
    --output text \
    --no-cli-pager)
export GA=$(/usr/local/bin/aws globalaccelerator list-accelerators \
    --region us-west-2 \
    --output text \
    --no-cli-pager \
    --query Accelerators[0].AcceleratorArn)

export GADNS=$(/usr/local/bin/aws globalaccelerator list-accelerators \
    --region us-west-2 \
    --output text \
    --no-cli-pager \
    --query Accelerators[0].DnsName)

export GALISTENER=$(/usr/local/bin/aws globalaccelerator list-listeners \
    --region us-west-2 \
    --accelerator-arn $GA \
    --output text \
    --no-cli-pager \
    --query Listeners[0].ListenerArn)    
# deploy second region
/usr/local/bin/aws cloudformation deploy \
    --region $SECONDARYREGION \
    --template-file ./secondary.cform \
    --stack-name lab-$SECONDARYREGION \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides EFSFileSystem=$SECONDARYEFSID Listener=$GALISTENER GlobalAcceleratorDns=$GADNS \
    --no-cli-pager

# establish write forwarding
/usr/local/bin/aws rds modify-db-cluster \
    --db-cluster-identifier secondary-aurora-cluster \
    --region $SECONDARYREGION \
    --enable-global-write-forwarding \
    --no-cli-pager

#scale out wordpress in secondary region
/usr/local/bin/aws ecs update-service \
    --region $SECONDARYREGION \
    --cluster wordpress-ecs-cluster \
    --service wordpress-service \
    --desired-count 3 \
    --no-cli-pager

#get a task id in primary region
export ECSTASK=$(/usr/local/bin/aws ecs list-tasks \
    --region $MAINREGION \
    --cluster wordpress-ecs-cluster \
    --output text \
    --query taskArns[0] \
    --service-name wordpress-service)

#update wordpress settings
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "session-manager-plugin.rpm"
sudo yum install -y session-manager-plugin.rpm
/usr/local/bin/aws ecs execute-command \
    --cluster wordpress-ecs-cluster \
	--region $MAINREGION \
    --task $ECSTASK \
    --container wordpress-container \
	--interactive \
    --command "wp --allow-root option update comment_previously_approved 0"

/usr/local/bin/aws ecs execute-command \
    --cluster wordpress-ecs-cluster \
	--region $MAINREGION \
    --task $ECSTASK \
    --container wordpress-container \
	--interactive \
    --command "wp --allow-root option update require_name_email 0"

export MAINALB=$(/usr/local/bin/aws cloudformation describe-stacks \
    --region $MAINREGION \
    --stack-name lab-$MAINREGION \
    --query Stacks[0].Outputs[0].OutputValue \
    --output text)

export SECONDARYALB=$(/usr/local/bin/aws cloudformation describe-stacks \
    --region $SECONDARYREGION \
    --stack-name lab-$SECONDARYREGION \
    --query Stacks[0].Outputs[0].OutputValue \
    --output text)

curl https://raw.githubusercontent.com/iizotov/aws-tech-summit-lab/main/bootstrap_post.txt -o bootstrap_post.txt

envsubst < ./bootstrap_post.txt > ./post.txt

export POST=$(cat ./post.txt)

/usr/local/bin/aws ecs execute-command \
    --cluster wordpress-ecs-cluster \
	--region $MAINREGION \
    --task $ECSTASK \
    --container wordpress-container \
	--interactive \
    --command "wp --allow-root post create --post_status=publish --user=admin --post_excerpt='You have deployed WordPress across two AWS regions: us-east-1 (primary) and ap-southeast-2 (hot read-only standby)... Click for more details' --post_title='(Click Me) Welcome to Tech Summit 2022' --post_content=\"$POST\""


/usr/local/bin/aws ecs execute-command \
    --cluster wordpress-ecs-cluster \
	--region $MAINREGION \
    --task $ECSTASK \
    --container wordpress-container \
	--interactive \
    --command "wp --allow-root post delete 1 --force"

#scale out wordpress in main region
/usr/local/bin/aws ecs update-service \
    --region $MAINREGION \
    --cluster wordpress-ecs-cluster \
    --service wordpress-service \
    --desired-count 3 \
    --no-cli-pager