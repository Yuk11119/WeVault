# RAM policies for the staging ECS

The account ID and Bucket name are already fixed for this staging deployment. Do not broaden any resource path.

Create these roles:

- `wevault-ecs-runtime-staging`: trusted service `ecs.aliyuncs.com`; attach `wevault-ecs-runtime-staging-policy.json` and bind it to the existing ECS instance.
- `wevault-oss-upload-staging`: trust only the runtime role using `wevault-workload-role-trust-policy.json`; attach `wevault-oss-upload-staging-policy.json`.
- `wevault-oss-download-staging`: same trust; attach `wevault-oss-download-staging-policy.json`.
- `wevault-backup-upload-staging`: same trust; attach `wevault-backup-upload-staging-policy.json`.

All roles remain free of console login and permanent AccessKeys.
