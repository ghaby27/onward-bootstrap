#!/usr/bin/env bash
# Builds a lab from Git, in dependency order:
#   account setup (GitHub connection, GitHub OIDC provider, budget) -> placeholder stacks
#   -> Git sync, one layer at a time.
# Git sync then deploys infra/<layer>/ from the lab repository.
#
# Usage: ./deploy.sh <path to lab repo>
#        (first run in an account: BUDGET_EMAIL=you@example.com ./deploy.sh <lab repo>)
# The lab repo holds lab.env (LAB=<short name>, LAYERS=(<layer> ...)) and may hold
# scripts/hooks/before-<layer>.sh, run just before that layer is synced.
# First run only: the GitHub connection must be approved once in the console; the script stops and says when.
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-onward-logistics} AWS_REGION=${AWS_REGION:-eu-west-1}
HERE=$(cd "$(dirname "$0")" && pwd)
LAB_REPO=$(cd "${1:?usage: deploy.sh <path to lab repo>}" && git rev-parse --show-toplevel)
ENV=dev
# shellcheck source=/dev/null
source "$LAB_REPO/lab.env"
: "${LAB:?lab.env must set LAB}"; [ "${#LAYERS[@]}" -le 5 ] || { echo "at most 5 layers"; exit 1; }
REMOTE=$(git -C "$LAB_REPO" remote get-url origin)
OWNER_REPO=${REMOTE#*github.com[:/]}; OWNER_REPO=${OWNER_REPO%.git}
TAGS=(Project=onward "Owner=Gabriel Anyaele" Environment=$ENV)

deploy() { # stack template [params...]
  local stack=$1 template=$2; shift 2
  aws cloudformation deploy --stack-name "$stack" --template-file "$HERE/templates/$template" \
    --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset --tags "${TAGS[@]}" \
    ${1:+--parameter-overrides "$@"} >/dev/null
  echo "  $stack: deployed"
}

stack_status() { aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo MISSING; }
output_count() { aws cloudformation describe-stacks --stack-name "$1" --query 'length(Stacks[0].Outputs || `[]`)' --output text; }

# Pushes a timestamp to infra/<layer>/deployment.yaml so Git sync sees a file change and deploys it.
trigger_sync() { # layer
  local file="infra/$1/deployment.yaml"
  git -C "$LAB_REPO" pull -q --ff-only origin main
  sed -i '/^# Last rebuilt:/d' "$LAB_REPO/$file"
  sed -i "1a # Last rebuilt: $(date -u +%FT%TZ) (onward-bootstrap/deploy.sh trigger for Git sync)" "$LAB_REPO/$file"
  git -C "$LAB_REPO" add "$file"
  git -C "$LAB_REPO" commit -q -m "chore: trigger git sync for $1"
  git -C "$LAB_REPO" push -q origin HEAD:main
  echo "  pushed a rebuild trigger for $1 (Git sync had nothing new to deploy)"
}

echo "1. GitHub connection (account)"
# Created once and then left alone; each lab links its own repository in its Git sync stack.
if [ "$(stack_status onward-$ENV-github-connection)" = MISSING ]; then
  deploy onward-$ENV-github-connection github-connection.yaml
else
  echo "  onward-$ENV-github-connection: exists"
fi
CONN=$(aws cloudformation describe-stacks --stack-name onward-$ENV-github-connection \
  --query "Stacks[0].Outputs[?OutputKey=='ConnectionArn'].OutputValue" --output text)
if [ "$(aws codeconnections get-connection --connection-arn "$CONN" --query Connection.ConnectionStatus --output text)" != AVAILABLE ]; then
  echo "  Approve connection onward-$ENV-github in the console (Developer Tools > Settings > Connections),"
  echo "  install the AWS Connector for GitHub app on the repositories, then run this script again."
  exit 1
fi

echo "2. GitHub OIDC provider (account)"
# Only one provider per URL can exist in an account, so an existing one is imported, never recreated.
if [ "$(stack_status onward-github-oidc)" = MISSING ]; then
  ARN=$(aws iam list-open-id-connect-providers --query \
    "OpenIDConnectProviderList[?ends_with(Arn, '/token.actions.githubusercontent.com')].Arn | [0]" --output text)
  if [ "$ARN" != None ]; then
    python3 -c "import sys; t=open(sys.argv[1]).read(); print(t[:t.index('Outputs:')])" \
      "$HERE/templates/github-oidc.yaml" > "${TMPDIR:-/tmp}/github-oidc-import.yaml"
    aws cloudformation create-change-set --stack-name onward-github-oidc --change-set-name import \
      --change-set-type IMPORT --template-body "file://${TMPDIR:-/tmp}/github-oidc-import.yaml" \
      --resources-to-import "[{\"ResourceType\":\"AWS::IAM::OIDCProvider\",\"LogicalResourceId\":\"GitHubOidcProvider\",\"ResourceIdentifier\":{\"Arn\":\"$ARN\"}}]" >/dev/null
    aws cloudformation wait change-set-create-complete --stack-name onward-github-oidc --change-set-name import
    aws cloudformation execute-change-set --stack-name onward-github-oidc --change-set-name import
    aws cloudformation wait stack-import-complete --stack-name onward-github-oidc
    echo "  onward-github-oidc: imported the existing provider"
  fi
fi
deploy onward-github-oidc github-oidc.yaml

echo "3. Budget alert (account)"
# The alert email lives in SSM (settings stack), never in Git. Pass BUDGET_EMAIL only to set or change it.
if [ -n "${BUDGET_EMAIL:-}" ]; then
  deploy onward-$ENV-settings settings.yaml BudgetAlertEmail="$BUDGET_EMAIL"
fi
if [ "$(stack_status onward-$ENV-settings)" = MISSING ]; then
  echo "  skipped: run once with BUDGET_EMAIL=you@example.com to store the alert address"
else
  deploy onward-$ENV-budget budget.yaml
fi

echo "4. Placeholder stacks ($LAB)"
for l in "${LAYERS[@]}"; do
  if [ "$(stack_status onward-$ENV-$LAB-$l)" = MISSING ]; then
    deploy onward-$ENV-$LAB-$l placeholder-stack.yaml
  else
    echo "  onward-$ENV-$LAB-$l: exists"
  fi
done

echo "5. Git sync, one layer at a time ($OWNER_REPO)"
SYNC_STACK=onward-$ENV-$LAB-git-sync
LAYER_PARAMS=(); for i in "${!LAYERS[@]}"; do LAYER_PARAMS+=("Layer$((i + 1))=${LAYERS[$i]}"); done
sync_params() { echo Lab="$LAB" ConnectionArn="$CONN" GitHubOwner="${OWNER_REPO%/*}" RepositoryName="${OWNER_REPO#*/}" "${LAYER_PARAMS[@]}" SyncedLayers="$1"; }
current=$(aws cloudformation describe-stacks --stack-name $SYNC_STACK \
  --query "Stacks[0].Parameters[?ParameterKey=='SyncedLayers'].ParameterValue" --output text 2>/dev/null || echo 0)
for i in "${!LAYERS[@]}"; do
  n=$((i + 1)); l=${LAYERS[$i]}; stack=onward-$ENV-$LAB-$l
  # Real stacks have outputs; placeholders do not.
  if [ "$(output_count "$stack")" -gt 0 ]; then
    echo "  $stack: already synced"; continue
  fi
  hook="$LAB_REPO/scripts/hooks/before-$l.sh"
  if [ -x "$hook" ]; then echo "  running $(basename "$hook")"; "$hook"; fi
  enabled_at=$(date +%s)
  if ! [ "${current:-0}" -ge "$n" ] 2>/dev/null; then
    # shellcheck disable=SC2046
    deploy $SYNC_STACK git-sync.yaml $(sync_params $n)
  fi
  # Git sync remembers the last commit it deployed to each stack name, even after the stack is
  # deleted, so on a rebuild a new sync config deploys nothing until a push changes the layer's
  # files. If no real sync starts within ~90s (none, or only "Nothing to sync"), push a timestamp
  # to the layer's deployment file.
  started=0
  for _ in $(seq 1 9); do
    read -r sync_start sync_msg < <(aws codestar-connections get-resource-sync-status --resource-name "$stack" \
      --sync-type CFN_STACK_SYNC --query '[LatestSync.StartedAt, join(`|`, LatestSync.Events[].Event)]' \
      --output text 2>/dev/null || true)
    if [ -n "${sync_start:-}" ] && [ "$sync_start" != None ] && \
       [ "$(date -d "$sync_start" +%s)" -ge "$enabled_at" ]; then
      case "${sync_msg:-}" in *"Nothing to sync"*) break ;; *) started=1; break ;; esac
    fi
    sleep 10
  done
  if [ $started = 0 ]; then trigger_sync "$l"; fi
  # Wait until Git sync has replaced the placeholder.
  outputs=0
  for _ in $(seq 1 80); do
    st=$(stack_status "$stack"); outputs=$(output_count "$stack")
    case "$st" in
      *ROLLBACK_COMPLETE|*FAILED) echo "  $stack: $st - check the stack events"; exit 1 ;;
      *_COMPLETE) [ "$outputs" -gt 0 ] && break ;;
    esac
    sleep 15
  done
  [ "$outputs" -gt 0 ] || { echo "  $stack: timed out waiting for Git sync"; exit 1; }
  echo "  $stack: $st"
done

echo "Done. Outputs:"
for l in "${LAYERS[@]}"; do
  aws cloudformation describe-stacks --stack-name onward-$ENV-$LAB-$l \
    --query "Stacks[0].Outputs[?contains(OutputKey, 'Url')].[OutputKey,OutputValue]" --output text
done
