#!/usr/bin/env bash
# Fails unless a pull request that changes what an approval guards has an
# approval on its head commit: a tag approve/netbox/NAME on that commit,
# signed with a key in the approvers file, whose message starts with
# "target: netbox". What an approval guards is NetBox's seed, the approvers
# file, and this check. A pull request that changes none of them passes.
# Platform ADR 0050.
#
# Usage: check-approval.sh APPROVERS BASE HEAD
#
# The caller passes the approvers file from the default branch and fetches
# the approval tags, so a pull request cannot bring its own key. Delivery
# checks the same tag before it changes NetBox (platform ADR 0046). This
# check keeps a commit pushed after the approval from being merged.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 APPROVERS BASE HEAD" >&2
  exit 2
fi
approvers=$1
base=$2
head=$3
guarded=(netbox/seed.json APPROVERS .github/workflows/approval.yml
  .github/scripts/check-approval.sh)

# An empty or unreadable file would make every signature "unknown key".
grep -Eq '^[^#[:space:]]+ +namespaces="git" +ssh-' "${approvers}"

# The pull request's changes as GitHub shows them, from where it left the
# base branch. A commit missing from the clone fails here, and does not pass
# as no change.
git cat-file -e "${head}^{commit}"
changed=$(git diff --name-only "${base}...${head}")
touched=()
for path in "${guarded[@]}"; do
  if grep -qxF "${path}" <<<"${changed}"; then
    touched+=("${path}")
  fi
done
if [ "${#touched[@]}" -eq 0 ]; then
  echo "The pull request changes nothing an approval guards"
  exit 0
fi
echo "The pull request changes ${touched[*]}, so its head needs an approval"

# "fully" is the trust level Git gives a key the file names, as in
# check-signatures.sh.
gitv=(git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="${approvers}"
  -c gpg.minTrustLevel=fully)
mapfile -t tags < <(git for-each-ref --points-at "${head}" \
  --format='%(refname:strip=2)' refs/tags/approve/netbox/)
for tag in "${tags[@]}"; do
  # The first line of the message, which follows the first empty line.
  message=$(git cat-file tag "refs/tags/${tag}" | sed -n '/^$/{n;p;q;}')
  if "${gitv[@]}" verify-tag "refs/tags/${tag}" 2>/dev/null &&
    [ "${message}" = "target: netbox" ]; then
    echo "ok      ${tag} approves ${head}"
    exit 0
  fi
  echo "FAILED  ${tag}: not signed with an approval key, or not for NetBox"
done
echo "No approval on ${head}. Sign a tag approve/netbox/NAME on it with the" \
  "approval key, push it, and run this check again." >&2
exit 1
