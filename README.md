# github-tag-action

A Github Action to automatically bump and tag master, on merge, with the latest SemVer formatted version.

[![Build Status](https://github.com/cmnhospitals/github-tag-action/workflows/Bump%20version/badge.svg)](https://github.com/cmnhospitals/github-tag-action/workflows/Bump%20version/badge.svg)
[![Stable Version](https://img.shields.io/github/v/tag/cmnhospitals/github-tag-action)](https://img.shields.io/github/v/tag/cmnhospitals/github-tag-action)
[![Latest Release](https://img.shields.io/github/v/release/cmnhospitals/github-tag-action?color=%233D9970)](https://img.shields.io/github/v/release/cmnhospitals/github-tag-action?color=%233D9970)

> Medium Post: [Creating A Github Action to Tag Commits](https://itnext.io/creating-a-github-action-to-tag-commits-2722f1560dec)

[<img src="https://miro.medium.com/max/1200/1*_4Ex1uUhL93a3bHyC-TgPg.png" width="400">](https://itnext.io/creating-a-github-action-to-tag-commits-2722f1560dec)

### Usage

```Dockerfile
name: Bump version
on:
  push:
    branches:
      - master
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
      with:
        fetch-depth: '0'
    - name: Bump version and push tag
      uses: cmnhospitals/github-tag-action@2.0.0
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

_NOTE: set the fetch-depth for `actions/checkout@v3` to be sure you retrieve all commits to look for the semver commit message._

#### Options

**Environment Variables**

- **GITHUB_TOKEN** ***(required)*** - Required for permission to tag the repo.
- **DEFAULT_BUMP** *(optional)* - Which type of bump to use when none explicitly provided (default: `minor`).
- **PREFIX** *(optional)* - Adds a prefix before version number (default: no prefix). Use `v` for traditional semantic versioning.
- **RELEASE_BRANCHES** *(optional)* - Comma separated list of branches (bash reg exp accepted) that will generate the release tags. Other branches and pull-requests generate versions postfixed with the commit hash and do not generate any tag. Examples: `master` or `.*` or `release.*,hotfix.*,master` ...
- **CUSTOM_TAG** *(optional)* - Set a custom tag, useful when generating tag based on f.ex FROM image in a docker image. **Setting this tag will skip all version calculation logic and use the custom tag directly for optimal performance!**
- **SOURCE** *(optional)* - Operate on a relative path under $GITHUB_WORKSPACE.
- **DRY_RUN** *(optional)* - Determine the next version without tagging the branch. The workflow can use the outputs `new_tag` and `tag` in subsequent steps. Possible values are ```true``` and ```false``` (default).
- **INITIAL_VERSION** *(optional)* - Set initial version before bump. Default `0.0.0`.
- **CUSTOM_VERSION** *(optional)* - Set custom major.minor version before bump. This setting will allow us to pass in a major.minor version (e.g., 2.3) and then add the patch number dynamically based on tags that already exist in your chosen context. **Using this setting will force DEFAULT_BUMP to 'patch' regardless of what is passed in**
- **TAG_CONTEXT** *(optional)* - Set the context of the previous tag. Possible values are `repo` (default) or `branch`.
- **PRERELEASE_SUFFIX** *(optional)* - Suffix for your prerelease versions, `beta` by default. Note this will only be used if a prerelease branch.
- **VERBOSE** *(optional)* - Print git logs. For some projects these logs may be very large. Possible values are ```true``` (default) and ```false```. 

#### Outputs

- **new_tag** - The value of the newly created tag.
- **new_version** - The value of the newly created tag without the prefix.
- **tag** - The value of the tag before running this action.
- **version** - The value of the tag before running this action without the prefix.
- **part** - The part of version which was bumped.

> **_Note:_** This action creates a [lightweight tag](https://developer.github.com/v3/git/refs/#create-a-reference).

### Bumping

**Manual Bumping:** Any commit message that includes `#major`, `#minor`, `#patch`, or `#none` will trigger the respective version bump. If two or more are present, the highest-ranking one will take precedence.
If `#none` is contained in the commit message, it will skip bumping regardless `DEFAULT_BUMP`.

**Automatic Bumping:** If no `#major`, `#minor` or `#patch` tag is contained in the commit messages, it will bump whichever `DEFAULT_BUMP` is set to (which is `minor` by default). Disable this by setting `DEFAULT_BUMP` to `none`.

> **_Note:_** This action **will not** bump the tag if the `HEAD` commit has already been tagged.

### Workflow

- Add this action to your repo
- Commit some changes
- Either push to master or open a PR
- On push (or merge), the action will:
  - Get latest tag
  - Bump tag with minor version unless any commit message contains `#major` or `#patch`
  - Pushes tag to github
  - If triggered on your repo's default branch (`master` or `main` if unchanged), the bump version will be a release tag.
  - If triggered on any other branch, a prerelease will be generated, depending on the bump, starting with `*-<PRERELEASE_SUFFIX>.1`, `*-<PRERELEASE_SUFFIX>.2`, ...

### Credits

[fsaintjacques/semver-tool](https://github.com/fsaintjacques/semver-tool)

[anothrNick/github-tag-action](https://github.com/anothrNick/github-tag-action)
