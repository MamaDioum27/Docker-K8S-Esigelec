#!/bin/bash
# Lance les 5 images du lab 1_ContainersAndDocker_2 sur AWS Fargate (cluster lab-docker-cluster)
# puis affiche les résultats : curl pour les serveurs web, logs CloudWatch pour les ubi-*.
set -e
export AWS_PAGER=""

REGION=eu-north-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REG=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com
CLUSTER=lab-docker-cluster
ROLE=arn:aws:iam::$ACCOUNT:role/ecsTaskExecutionRole
LOG_GROUP=/ecs/lab-docker-2
APPS="hello-world-nginx hello-java ubi-echo ubi-sleep ubi-info"

# Réseau : VPC par défaut + groupe de sécurité créé pour la 1re app (8080 ouvert)
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=lab-docker-sg \
      --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" = "None" ] || [ -z "$SG" ]; then
  VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  SG=$(aws ec2 create-security-group --group-name lab-docker-sg --description "lab docker 8080" \
        --vpc-id "$VPC" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null
fi
SUBNETS=$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
           --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
echo "Groupe de sécurité : $SG"
echo "Sous-réseaux       : $SUBNETS"

# Groupe de logs CloudWatch (le rôle d'exécution ne peut pas le créer lui-même)
aws logs create-log-group --log-group-name "$LOG_GROUP" 2>/dev/null || true

declare -A TASKS
for d in $APPS; do
  CPU=256; MEM=512
  [ "$d" = "hello-java" ] && MEM=1024   # la JVM demande -Xmx512m, 512 Mo ne suffisent pas
  PORTS='[]'
  case $d in hello-*) PORTS='[{"containerPort":8080,"protocol":"tcp"}]' ;; esac

  echo "===== $d"
  aws ecs register-task-definition \
    --family "$d" \
    --requires-compatibilities FARGATE \
    --network-mode awsvpc \
    --cpu $CPU --memory $MEM \
    --execution-role-arn "$ROLE" \
    --runtime-platform cpuArchitecture=X86_64,operatingSystemFamily=LINUX \
    --container-definitions "[{\"name\":\"app\",\"image\":\"$REG/$d:latest\",\"essential\":true,\"portMappings\":$PORTS,\"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"$LOG_GROUP\",\"awslogs-region\":\"$REGION\",\"awslogs-stream-prefix\":\"$d\"}}}]" \
    --query 'taskDefinition.taskDefinitionArn' --output text

  TASKS[$d]=$(aws ecs run-task --cluster $CLUSTER --launch-type FARGATE --task-definition "$d" \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" \
    --query 'tasks[0].taskArn' --output text)
  echo "tâche lancée : ${TASKS[$d]##*/}"
done

echo
echo "Attente du démarrage des tâches (90 s)..."
sleep 90

for d in $APPS; do
  T=${TASKS[$d]}
  STATUS=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$T" --query 'tasks[0].lastStatus' --output text)
  echo
  echo "===================== $d  (statut : $STATUS)"
  case $d in
    hello-*)
      ENI=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$T" \
            --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
      IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" \
            --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
      URL=http://$IP:8080/
      [ "$d" = "hello-java" ] && URL=http://$IP:8080/api/hello
      echo "curl $URL"
      curl -s -m 10 "$URL" || echo "(pas de réponse : la tâche démarre peut-être encore, relance la commande ci-dessus)"
      echo
      ;;
    *)
      aws logs filter-log-events --log-group-name "$LOG_GROUP" --log-stream-name-prefix "$d/" \
        --query 'events[].message' --output text | tr '\t' '\n' | head -25
      ;;
  esac
done

echo
echo "Pour tout arrêter ensuite :"
echo "  for t in \$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[]' --output text); do aws ecs stop-task --cluster $CLUSTER --task \$t --query task.lastStatus --output text; done"
