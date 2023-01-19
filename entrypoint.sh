#!/bin/bash

set -o pipefail

# config
append_commit_SHA=${APPEND_COMMIT_SHA:-false}
default_semvar_bump=${DEFAULT_BUMP:-minor}
prefix=${PREFIX:-v}
release_branches=${RELEASE_BRANCHES:-master,main}
custom_tag=${CUSTOM_TAG}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
initial_version=${INITIAL_VERSION:-0.0.0}
custom_version=${CUSTOM_VERSION}
tag_context=${TAG_CONTEXT:-repo}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-false}
# since https://github.blog/2022-04-12-git-security-vulnerability-announced/ runner uses?
git config --global --add safe.directory /github/workspace

# if custom_version is set update default_semver_bump to patch
if [[ -n "${custom_version}" ]]; then
  default_semvar_bump="patch"
fi

cd ${GITHUB_WORKSPACE}/${source}

echo "*** CONFIGURATION ***"
echo -e "\tAPPEND_COMMIT_SHA: ${append_commit_SHA}"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tPREFIX: ${prefix}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tCUSTOM_VERSION: ${custom_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"

# get current commit hash
commit=$(git rev-parse HEAD)
echo "commit = $commit"

current_branch=$(git branch --show-current)
echo "current_branch = $current_branch"

#if current_branch is an empty string, we are in detached head state and should use the HEAD_REF env var
if [[ "${current_branch}" == "" ]]
then
    current_branch=${GITHUB_HEAD_REF}
    commit=$(git rev-parse origin/$GITHUB_HEAD_REF)
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

# get latest tags based on context
case "$tag_context" in
    *repo*)
        #if this is a prerelease grab all of the tags, including prerelease tags, otherwise just grab a list of the non-prerelease tags
        if [ $pre_release == "true" ]
        then
            taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "^$prefix$custom_version")"
        else
            taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "$tagFmt")"
        fi

        if [ -n "$custom_version" ]
        then
            echo "Using custom version: $custom_version"
            #if taglist is empty, add .0 to the end of custom_version and set tag to that
            if [ -z "$taglist" ]
            then
                tag="$prefix$custom_version.0"
                new_minor_version=true
            else
                tag="$(echo "$taglist" | head -n 1)"
                new_minor_version=false
            fi
        else
            tag="$(echo "$taglist" | head -n 1)"
        fi
        ;;
    *branch*)
        #if this is a prerelease grab all of the tags, including prerelease tags, otherwise just grab a list of the non-prerelease tags
        if [ $pre_release == "true" ]
        then
            taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "^$prefix$custom_version")"
        else
            taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "$tagFmt")"
        fi
        #if custom tag is set, find all of the similar tags and use the highest one
        if [ -n "$custom_version" ]
        then
            echo "Using custom version: $custom_version"
            #if taglist is empty, add .0 to the end of custom_version and set tag to that
            if [ -z "$taglist" ]
            then
                tag="$prefix$custom_version.0"
                new_minor_version=true
            else
                tag="$(echo "$taglist" | head -n 1)"
                new_minor_version=false
            fi
        else
            tag="$(echo "$taglist" | head -n 1)"
        fi
        ;;
    * ) echo "Unrecognized context"; exit 1;;
esac

version=${tag#"$prefix"}

echo "new_minor_version = $new_minor_version"
echo "taglist = $taglist"
echo "tag = $tag"
echo "version = $version"

# if there are none, start tags at INITIAL_VERSION which defaults to ($prefix0.0.0)
if [ -z "$tag" ]
then
    log=$(git log --pretty='%B')
    tag="$prefix$initial_version"
    version=${tag#"$prefix"}
else
    if [ $new_minor_version == "true" ]
    then
        log=$(git log --pretty='%B' -1)
    else
        log=$(git log --pretty='%B' "${tag}"..HEAD)
    fi
fi

if [ $new_minor_version == "false" ]
then
    # get current commit hash for tag
    tag_commit=$(git rev-list -n 1 "${tag}")

    if [ "$tag_commit" == "$commit" ]; then
        echo "No new commits since previous tag. Skipping."
        echo "tag=$tag" >> $GITHUB_OUTPUT
        echo "version=$version" >> $GITHUB_OUTPUT
        exit 0
    fi
fi

# echo log if verbose is wanted
if $verbose
then
  echo $log
fi

# get the semver bump
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
            #if new_minor_version is true, we don't need to bump anything, so just set new, new_version, and part
            if [ "$new_minor_version" == "true" ]
            then
                new=$prefix$(semver $version); new_version=${new#"$prefix"}; part="none";
            else
                new=$prefix$(semver -i "$default_semvar_bump" "$version"); new_version=${new#"$prefix"}; part=$default_semvar_bump;
            fi
        fi
        ;;
esac

if $pre_release
then
    # Already a prerelease available, bump it. else start at .0
    if [[ "$tag" == *"$new"* ]] && [[ "$new_minor_version" == "false" ]]; then
        new=$prefix$(semver -i prerelease "${version}" --preid "${suffix}"); new_version=${new#"$prefix"}; part="prerelease"
    else
        new="$new-$suffix.0"; new_version=${new#"$prefix"}; part="prerelease"
    fi
fi

echo $part

# if $custom_tag is set, use that instead of the calculated tag

if [ ! -z $custom_tag ]
then
    new="$prefix$custom_tag"
    new_version=${new#"$prefix"}
fi

#if append_commit is true, append the commit hash to the end of the tag and version
if [ $append_commit_SHA == "true" ]
then
    short_commit=$(echo $commit | cut -c-8)
    new="$new+$short_commit"
    new_version="$new_version+$short_commit"
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
