#!/bin/sh

set -e

SCRIPT_PATH=$(dirname $(readlink -f $0))
. $SCRIPT_PATH/../app-config.sh

if [ "$1" = "" ]; then
    echo "No environment set"
    exit
else
    PROJECT_ENVIRONMENT="$1"
    if [ ! -f $SCRIPT_PATH/../$PROJECT_ENVIRONMENT/config.sh ] || [ "$BUILD" = "" ]; then
        echo "Please initialize deploy/$PROJECT_ENVIRONMENT/config.sh with vars BUILD, PROJECT_ENVIRONMENT, SERVICE_NAME, GIT_REPO, and GIT_BRANCH"
        exit
    fi
    . $SCRIPT_PATH/../$PROJECT_ENVIRONMENT/config.sh
fi

WORK_DIR=$SCRIPT_PATH/../work
BUILD_REPO=$WORK_DIR/repo/
DEPLOY_REPO=$WORK_DIR/deploy-repo

clean_dirs() {
	if [ -d $WORK_DIR ]; then
		echo "Deleting deployment work dir $SCRIPT_PATH/../work"
		rm -rf $WORK_DIR
	fi
}

clean_dirs

BUILD_REPO=$SCRIPT_PATH/../work/repo/
echo "Creating repo to build program at $BUILD_REPO"
mkdir -p $BUILD_REPO
cd $BUILD_REPO
git init
git remote add deploy-build $GIT_REPO
git pull deploy-build $GIT_BRANCH
echo "Checked out $GIT_BRANCH from $GIT_REPO"

PROJECT_ENVIRONMENT=$PROJECT_ENVIRONMENT sh $SCRIPT_PATH/$BUILD.sh

if [ ! -d $SCRIPT_PATH/../work/deploy-repo ]; then
	echo "No deployment repo created by $BUILD script. exiting"
	exit
fi

TIMESTAMP=$(date +%s)
BARE_REPO_SCRIPT_DIR=/tmp/deployer-$TIMESTAMP

mkdir -p $BARE_REPO_SCRIPT_DIR
cat $SCRIPT_PATH/../app-config.sh $SCRIPT_PATH/../$PROJECT_ENVIRONMENT/config.sh > $BARE_REPO_SCRIPT_DIR/config.sh
cp $SCRIPT_PATH/bare-repo.sh $BARE_REPO_SCRIPT_DIR/
cp $SCRIPT_PATH/../$PROJECT_ENVIRONMENT/git-hook-post-receive-$BUILD $BARE_REPO_SCRIPT_DIR/

echo "Copying scripts to create bare git repo"
scp -r $BARE_REPO_SCRIPT_DIR $DEPLOYMENT_SSH_USER@$DEPLOYMENT_SERVER:/tmp/
ssh -t $DEPLOYMENT_SSH_USER@$DEPLOYMENT_SERVER << EOSSH
cd $BARE_REPO_SCRIPT_DIR && sh ./bare-repo.sh
EOSSH

REMOTE_GIT_BARE_REPO=ssh://$DEPLOYMENT_SSH_USER@$DEPLOYMENT_SERVER/home/$DEPLOYMENT_SSH_USER/repos/$SERVICE_NAME/$PROJECT_ENVIRONMENT.git
echo "Deploying $PROJECT_ENVIRONMENT to $REMOTE_GIT_BARE_REPO"

cd $SCRIPT_PATH/../work/deploy-repo
git remote add fincon-dev $REMOTE_GIT_BARE_REPO
git push fincon-dev master -f
clean_dirs
