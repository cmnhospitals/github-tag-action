FROM node:22-alpine
LABEL "repository"="https://github.com/cmnhospitals/github-tag-action"
LABEL "homepage"="https://github.com/cmnhospitals/github-tag-action"
LABEL "maintainer"="Justin Newman"

COPY entrypoint.sh /entrypoint.sh

RUN apk --no-cache add bash git curl jq && npm install -g semver

ENTRYPOINT ["/entrypoint.sh"]
