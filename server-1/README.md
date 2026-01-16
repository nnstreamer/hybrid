# server-1

This is a relay server of the PCC system.

## Version 0.001, the first prototype

This is a relay server directly created by the default image of openpcc.

With minimal changes from the default packing script of openpcc, this just helps
automate the packing and deploying steps for PCC system prototyping.

Further changes or rebasing on TAOS-D will be done in later versions.

At this stage, this passes all the requests from client; howver, in the later versions, this should pass authenticated clients only, which will use server-3-auth.
