#!/bin/bash

set -o pipefail

# Configuration
append_commit_SHA=${APPEND_COMMIT_SHA:-false}
default_semver_bump=${DEFAULT_BUMP:-minor}
# Handle PREFIX - default to no prefix (modern approach)
prefix=${PREFIX:-""}
release_branches=${RELEASE_BRANCHES:-master,main}
custom_tag=${CUSTOM_TAG}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
initial_version=${INITIAL_VERSION:-0.0.0}
custom_version=${CUSTOM_VERSION}
tag_context=${TAG_CONTEXT:-repo}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-false}
# Set safe directory due to git security vulnerability (https://github.blog/2022-04-12-git-security-vulnerability-announced/)
git config --global --add safe.directory /github/workspace

# If custom_version is set, update default_semver_bump to patch
if [[ -n "${custom_version}" ]]; then
  default_semver_bump="patch"
fi

cd ${GITHUB_WORKSPACE}/${source}

echo "*** CONFIGURATION ***"
echo -e "\tAPPEND_COMMIT_SHA: ${append_commit_SHA}"
echo -e "\tDEFAULT_BUMP: ${default_semver_bump}"
echo -e "\tPREFIX: '${prefix}'"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tCUSTOM_VERSION: ${custom_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"

# Get current commit hash
commit=$(git rev-parse HEAD)
echo "commit = $commit"

current_branch=$(git branch --show-current)
echo "current_branch = $current_branch"

# If current_branch is empty, we are in detached head state and should use the HEAD_REF env var
if [[ "${current_branch}" == "" ]]
then
    current_branch=${GITHUB_HEAD_REF}
    commit=$(git rev-parse "origin/$GITHUB_HEAD_REF")
fi

# If custom_tag is set, skip all version calculation and use it directly
if [ -n "$custom_tag" ]; then
    echo "CUSTOM_TAG is set. Skipping version calculation and using custom tag: $custom_tag"
    
    # Set basic variables for custom tag flow
    tag=""  # No previous tag when using custom
    version=""  # No previous version when using custom
    new="$prefix$custom_tag"
    new_version=${new#"$prefix"}
    part="custom"
    
    # If append_commit is true, append the commit hash to the end of the tag and version
    if [ "$append_commit_SHA" == "true" ]; then
        short_commit=$(echo "$commit" | cut -c-8)
        new="$new+$short_commit"
        new_version="$new_version+$short_commit"
        echo -e "Using custom tag: $custom_tag\nAppending shortened commit hash to the end:\n\tNew Tag: $new\n\tNew Version: $new_version"
    else
        echo -e "Using custom tag:\n\tNew tag: $new\n\tNew version: $new_version"
    fi
    
    # Set outputs
    echo "tag=$tag" >> $GITHUB_OUTPUT
    echo "version=$version" >> $GITHUB_OUTPUT
    echo "new_tag=$new" >> $GITHUB_OUTPUT
    echo "new_version=$new_version" >> $GITHUB_OUTPUT
    echo "part=$part" >> $GITHUB_OUTPUT
    
    # Use dry run to determine the next tag
    if "$dryrun"; then
        echo "Dry run mode - would create tag: $new"
        exit 0
    fi 
    
    # Fetch tags (needed for tag creation)
    git fetch --tags
    
    # Create local git tag
    git tag "$new"
    
    # Push new tag ref to GitHub
    dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
    full_name=$GITHUB_REPOSITORY
    git_refs_url=$(jq .repository.git_refs_url "$GITHUB_EVENT_PATH" | tr -d '"' | sed 's/{\/sha}//g')
    
    echo "$dt: **pushing tag $new to repo $full_name"
    
    git_refs_response=$(
    curl -s -X POST "$git_refs_url" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -d @- << EOF

{
  "ref": "refs/tags/$new",
  "sha": "$commit"
}
EOF
    )
    
    git_ref_posted=$( echo "${git_refs_response}" | jq -r .ref )
    
    echo -e "\n::debug::${git_refs_response}"
    if [ "${git_ref_posted}" = "refs/tags/${new}" ]; then
        exit 0
    else
        echo "::error::Tag was not created properly."
        exit 1
    fi
fi

pre_release="true"
new_minor_version="false"
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
        if [[ "${current_branch}" == "$b" ]]
        then
            echo "yes"
            pre_release="false"
        else
            echo "no"
        fi
    fi
done
echo "pre_release = $pre_release"

# Fetch tags
git fetch --tags

# Build regex pattern - handle empty prefix case
if [ -n "$prefix" ]; then
    tagFmt="^($prefix)?[0-9]+\.[0-9]+\.[0-9]+(-$suffix\.[0-9]+)?$"
else
    tagFmt="^[0-9]+\.[0-9]+\.[0-9]+(-$suffix\.[0-9]+)?$"
fi

# Get latest tag that looks like a semver (with or without prefix)
case "$tag_context" in
    *repo*)
        if [ -n "$custom_version" ]
        then
            echo "Using custom version: $custom_version"
            # Get all of the tags
            if [ -n "$prefix" ]; then
                taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "^$prefix$custom_version")"
            else
                taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "^$custom_version")"
            fi
            # Strip off the prefix from each tag
            taglist=${taglist//"$prefix"}
            # If taglist is empty, add .0 to the end of custom_version and set tag to that
            if [ -z "$taglist" ]
            then
                tag="$prefix$custom_version.0"
                new_minor_version=true
            else
                taglist="$(semver $taglist | tac)"
                tag="$prefix$(echo "$taglist" | head -n 1)"
                new_minor_version=false
            fi
            # Order the list according to semver rules in descending order so the greatest version number is on top
            version=${tag#"$prefix"}
        else
            taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "$tagFmt")"
            tag="$prefix$(echo "$taglist" | head -n 1)"
            version=${tag#"$prefix"}
        fi
        ;;
    *branch*) 
        # If custom tag is set, find all of the similar tags and use the highest one
        if [ -n "$custom_version" ]
        then
            echo "Using custom version: $custom_version"
            # Get all of the tags
            if [ -n "$prefix" ]; then
                taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "^$prefix$custom_version")"
            else
                taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "^$custom_version")"
            fi
            # Strip off the prefix from each tag
            taglist=${taglist//"$prefix"}
            # If taglist is empty, add .0 to the end of custom_version and set tag to that
            if [ -z "$taglist" ]
            then
                tag="$prefix$custom_version.0"
                new_minor_version=true
            else
                taglist="$(semver $taglist | tac)"
                tag="$prefix$(echo "$taglist" | head -n 1)"
                new_minor_version=false
            fi
            # Order the list according to semver rules in descending order so the greatest version number is on top
            version=${tag#"$prefix"}
        else
            taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "$tagFmt")"
            if [ -n "$prefix" ]; then
                taglist="$prefix$taglist"
            fi
            tag="$(echo "$taglist" | head -n 1)"
            version=${tag#"$prefix"}
        fi
        ;;
    * ) echo "Unrecognized context"; exit 1;;
esac

# If there are none, start tags at INITIAL_VERSION which defaults to ($prefix0.0.0)
if [ -z "$tag" ]
then
    log=$(git log --pretty='%B')
    tag="$prefix$initial_version"
    version=${tag#"$prefix"}
else
    if [ "$new_minor_version" == "true" ]
    then
        log=$(git log --pretty='%B' -1)
    else
        log=$(git log --pretty='%B' "${tag}"..HEAD)
    fi
fi

if [ "$new_minor_version" == "false" ]
then
    # Get current commit hash for tag
    tag_commit=$(git rev-list -n 1 "${tag}")

    if [ "$tag_commit" == "$commit" ]; then
        echo "No new commits since previous tag. Skipping."
        echo "tag=$tag" >> $GITHUB_OUTPUT
        echo "version=$version" >> $GITHUB_OUTPUT
        exit 0
    fi
fi

# Echo log if verbose is wanted
if "$verbose"
then
    echo -e "Git Log:\n$log"
    echo "new_minor_version = $new_minor_version"
    echo -e "taglist:\n$taglist"
    echo "tag = $tag"
    echo "version = $version"
fi

# Get the semver bump
case "$log" in
    *#major* ) new=$prefix$(semver -i major $version); new_version=${new#"$prefix"}; part="major";;
    *#minor* ) new=$prefix$(semver -i minor $version); new_version=${new#"$prefix"}; part="minor";;
    *#patch* ) new=$prefix$(semver -i patch $version); new_version=${new#"$prefix"}; part="patch";;
    *#none* )
        echo "Default bump was set to none. Skipping."; echo "tag=$tag" >> $GITHUB_OUTPUT; echo "version=$version" >> $GITHUB_OUTPUT; exit 0;;
    * )
        if [ "$default_semver_bump" == "none" ]; then
            echo "Default bump was set to none. Skipping."; echo "tag=$tag" >> $GITHUB_OUTPUT; echo "version=$version" >> $GITHUB_OUTPUT; exit 0
        else
            # If new_minor_version is true, we don't need to bump anything, so just set new, new_version, and part
            if [ "$new_minor_version" == "true" ]
            then
                new=$prefix$(semver $version); new_version=${new#"$prefix"}; part="none";
            else
                new=$prefix$(semver -i "$default_semver_bump" "$version"); new_version=${new#"$prefix"}; part=$default_semver_bump;
            fi
        fi
        ;;
esac

if "$pre_release"
then
    # Already a prerelease available, bump it. else start at .0
    if [[ "$tag" == *"$new"* ]] && [[ "$new_minor_version" == "false" ]]; then
        new=$prefix$(semver -i prerelease "${version}" --preid "${suffix}"); new_version=${new#"$prefix"}; part="prerelease"
    else
        new="$new-$suffix.0"; new_version=${new#"$prefix"}; part="prerelease"
    fi
fi

# Note: custom_tag logic has been moved to early exit above for efficiency

# If append_commit is true, append the commit hash to the end of the tag and version
if [ "$append_commit_SHA" == "true" ]
then
    short_commit=$(echo "$commit" | cut -c-8)
    new="$new+$short_commit"
    new_version="$new_version+$short_commit"

    echo -e "Bumping previous version: ${version} --> ${new_version%"+$short_commit"}\nAppending shortened commit hash to the end of the tag and version strings:\n\tNew Tag: $new\n\tNew Version: $new_version"
else
    echo -e "Bumping previous version: ${version} --> ${new_version}\n\tNew tag: $new \n\tNew version: $new_version"
fi

# Set outputs
echo "tag=$tag" >> $GITHUB_OUTPUT
echo "version=$version" >> $GITHUB_OUTPUT
echo "new_tag=$new" >> $GITHUB_OUTPUT
echo "new_version=$new_version" >> $GITHUB_OUTPUT
echo "part=$part" >> $GITHUB_OUTPUT

# Use dry run to determine the next tag
if "$dryrun"
then
    exit 0
fi 

# Create local git tag
git tag "$new"

# Push new tag ref to GitHub
dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
full_name=$GITHUB_REPOSITORY
git_refs_url=$(jq .repository.git_refs_url "$GITHUB_EVENT_PATH" | tr -d '"' | sed 's/{\/sha}//g')

echo "$dt: **pushing tag $new to repo $full_name"

git_refs_response=$(
curl -s -X POST "$git_refs_url" \
-H "Authorization: token $GITHUB_TOKEN" \
-d @- << EOF

{
  "ref": "refs/tags/$new",
  "sha": "$commit"
}
EOF
)

git_ref_posted=$( echo "${git_refs_response}" | jq -r .ref )

echo -e "\n::debug::${git_refs_response}"
if [ "${git_ref_posted}" = "refs/tags/${new}" ]; then
  exit 0
else
  echo "::error::Tag was not created properly."
  exit 1
fi
