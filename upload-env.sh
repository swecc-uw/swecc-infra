#!/bin/bash

if [ ! -f ./.env.prod ]; then
  echo "Error: .env.prod file not found in current directory"
  exit 1
fi

if ! command -v gh &> /dev/null; then
  echo "Error: GitHub CLI (gh) is not installed or not in PATH"
  exit 1
fi

if ! gh auth status &> /dev/null; then
  echo "Error: Not logged in to GitHub CLI. Please run 'gh auth login' first"
  exit 1
fi

while IFS= read -r line || [ -n "$line" ]; do
  # skip empty lines and comments
  if [[ -z "$line" || "$line" == \#* ]]; then
    continue
  fi
  
  key=$(echo "$line" | cut -d= -f1)
  value=$(echo "$line" | cut -d= -f2-)
  
  echo "Setting variable: $key, value: $value"
  gh secret set "$key" --body "$value" --repo swecc-uw/swecc-infra
done < ./.env.prod

echo "All variables from .env.prod have been added to GitHub repository swecc-uw/swecc-infra"