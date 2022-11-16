#!/bin/bash

set -o pipefail

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
prefix=${PREFIX:-v}
release_branches=${RELEASE_BRANCHES:-master,main}
custom_tag=${CUSTOM_TAG}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
initial_version=${INITIAL_VERSION:-0.0.0}
tag_context=${TAG_CONTEXT:-repo}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-false}
# since https://github.blog/2022-04-12-git-security-vulnerability-announced/ runner uses?
git config --global --add safe.directory /github/workspace

cd ${GITHUB_WORKSPACE}/${source}

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tPREFIX: ${prefix}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"

current_branch=$(git branch --show-current)

if [[ "${current_branch}" == "" ]]
then
    current_branch=${GITHUB_HEAD_REF}
fi

pre_release="true"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    echo -n "Is $b a match for ${current_branch}?: "
    if [[ $b == *.* ]]
    then
        if [[ "${current_branch}" =~ $b ]]
        then
            echo "yes"
            pre_release="false"
        else
            echo "no"
        fi
    else
        if [[ "${current_branch}" == $b ]]
        then
            echo "yes"
            pre_release="false"
        else
            echo "no"
        fi
    fi
done
echo "pre_release = $pre_release"

# fetch tags
git fetch --tags
    
tagFmt="^($prefix)?[0-9]+\.[0-9]+\.[0-9]+(-$suffix\.[0-9]+)?$"

# get latest tag that looks like a semver (with or without v)
case "$tag_context" in
    *repo*) 
        taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "$tagFmt")"
        tag="$(echo "$taglist" | head -n 1)"
        version=${tag#"$prefix"}
        ;;
    *branch*) 
        taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "$tagFmt")"
        tag="$(echo "$taglist" | head -n 1)"
        version=${tag#"$prefix"}
        ;;
    * ) echo "Unrecognized context"; exit 1;;
esac

# if there are none, start tags at INITIAL_VERSION which defaults to ($prefix0.0.0)
if [ -z "$tag" ]
then
    log=$(git log --pretty='%B')
    tag="$prefix$initial_version"
    version=${tag#"$prefix"}
else
    log=$(git log "${tag}"..HEAD --pretty='%B')
fi

# get current commit hash for tag
tag_commit=$(git rev-list -n 1 "${tag}")

# get current commit hash
commit=$(git rev-parse HEAD)

if [ "$tag_commit" == "$commit" ]; then
    echo "No new commits since previous tag. Skipping."
    echo "tag=$tag" >> $GITHUB_OUTPUT
    echo "version=$version" >> $GITHUB_OUTPUT
    exit 0
fi

# echo log if verbose is wanted
if $verbose
then
  echo $log
fi

case "$log" in
    *#major* ) new=$prefix$(semver -i major $version); new_version=${new#"$prefix"}; part="major";;
    *#minor* ) new=$prefix$(semver -i minor $version); new_version=${new#"$prefix"}; part="minor";;
    *#patch* ) new=$prefix$(semver -i patch $version); new_version=${new#"$prefix"}; part="patch";;
    *#none* )
        echo "Default bump was set to none. Skipping."; echo "tag=$tag" >> $GITHUB_OUTPUT; echo "version=$version" >> $GITHUB_OUTPUT; exit 0;;
    * )
        if [ "$default_semvar_bump" == "none" ]; then
            echo "Default bump was set to none. Skipping."; echo "tag=$tag" >> $GITHUB_OUTPUT; echo "version=$version" >> $GITHUB_OUTPUT; exit 0
        else
            new=$prefix$(semver -i "${default_semvar_bump}" "${version}"); new_version=${new#"$prefix"}; part=$default_semvar_bump
        fi
        ;;
esac

if $pre_release
then
    # Already a prerelease available, bump it. else start at .0
    if [[ "$tag" == *"$new"* ]]; then
        new=$prefix$(semver -i prerelease "${version}" --preid "${suffix}"); new_version=${new#"$prefix"}; part="pre-$part"
    else
        new="$new-$suffix.0"; new_version=${new#"$prefix"}; part="pre-$part"
    fi
fi

echo $new
echo $part

if [ ! -z $custom_tag ]
then
    new="$prefix$custom_tag"
    new_version=${new#"$prefix"}
    if $pre_release
    then
        # Already a prerelease available, bump it. else start at .0
        if [[ "$tag" == *"$new"* ]]; then
            new=$prefix$(semver -i prerelease "${custom_tag}" --preid "${suffix}"); new_version=${new#"$prefix"}; part="pre-$part"
        else
            new="$new-$suffix.0"; new_version=${new#"$prefix"}; part="pre-$part"
        fi
    fi
fi

echo -e "Bumping tag ${tag} - Version: ${version} \n\tNew tag: ${new} \n\tNew version: ${new_version}"

# set outputs
echo "tag=$tag" >> $GITHUB_OUTPUT
echo "version=$version" >> $GITHUB_OUTPUT
echo "new_tag=$new" >> $GITHUB_OUTPUT
echo "new_version=$new_version" >> $GITHUB_OUTPUT
echo "part=$part" >> $GITHUB_OUTPUT

# use dry run to determine the next tag
if $dryrun
then
    exit 0
fi 

# create local git tag
git tag $new

# push new tag ref to github
dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
full_name=$GITHUB_REPOSITORY
git_refs_url=$(jq .repository.git_refs_url $GITHUB_EVENT_PATH | tr -d '"' | sed 's/{\/sha}//g')

echo "$dt: **pushing tag $new to repo $full_name"

git_refs_response=$(
curl -s -X POST $git_refs_url \
-H "Authorization: token $GITHUB_TOKEN" \
-d @- << EOF

{
  "ref": "refs/tags/$new",
  "sha": "$commit"
}
EOF
)

git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

echo "::debug::${git_refs_response}"
if [ "${git_ref_posted}" = "refs/tags/${new}" ]; then
  exit 0
else
  echo "::error::Tag was not created properly."
  exit 1
fi
