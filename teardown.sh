#!/usr/bin/env bash
# Deletes a lab's stacks in reverse dependency order, then its Git sync stack (so the
# next deploy.sh recreates the sync configs). Keeps the account setup (GitHub connection,
# OIDC provider, settings, budget) so a rebuild needs no console step.
# Runs the lab's scripts/hooks/before-teardown.sh first if it exists (e.g. to empty buckets).
# Usage: ./teardown.sh <path to lab repo>
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-onward-logistics} AWS_REGION=${AWS_REGION:-eu-west-1}
LAB_REPO=$(cd "${1:?usage: teardown.sh <path to lab repo>}" && git rev-parse --show-toplevel)
ENV=dev
# shellcheck source=/dev/null
source "$LAB_REPO/lab.env"

hook="$LAB_REPO/scripts/hooks/before-teardown.sh"
if [ -x "$hook" ]; then echo "Running $(basename "$hook")"; "$hook"; fi

stacks=()
for ((i = ${#LAYERS[@]} - 1; i >= 0; i--)); do stacks+=("onward-$ENV-$LAB-${LAYERS[$i]}"); done
stacks+=("onward-$ENV-$LAB-git-sync")
for stack in "${stacks[@]}"; do
  if aws cloudformation describe-stacks --stack-name "$stack" >/dev/null 2>&1; then
    echo "Deleting $stack"
    aws cloudformation delete-stack --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --stack-name "$stack"
  fi
done
echo "Lab $LAB deleted. Rebuild with: $(dirname "$0")/deploy.sh $LAB_REPO"
