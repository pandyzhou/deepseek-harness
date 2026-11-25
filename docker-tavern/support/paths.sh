# Where the install lives. The install records these paths in its own files
# (links between its packages, the package store), so they are the same while
# the image is built and in every container, whatever the environment says.
TAVERN_HOME=/data/dsh-tavern
TAVERN_APP=$TAVERN_HOME/apps/dsh-tavern
SEED=/opt/dsh-tavern/seed.tar.zst
SEED_INFO=/opt/dsh-tavern/seed.json

export HOME=/data/home
export DSH_TAVERN_CLI_HOME=$TAVERN_HOME
# The launcher takes these for the home of another, older install.
unset DSH_HOME DSH_TAVERN_LEGACY_DSH_HOME
