# Troubleshooting

- Check cloud-init logs at /var/log/cloud-init-output.log
- Check bootstrap script logs for failed stage
- Verify instance IAM role has S3 read permissions for license object
- If using SPLUNK_PACKAGE_S3_KEY, verify the instance IAM role has s3:GetObject access for that RPM object key
- Verify instance IAM role has S3 list/get permissions for app package prefix in the license bucket
- Confirm security group CIDRs allow expected source access
- Validate Docker and NVIDIA runtime with nvidia-smi and docker info
- Inspect Splunk logs in $SPLUNK_HOME/var/log/splunk
- For Ansible installs, verify local ansible-playbook is available and SSH key path is correct
- For app install failures, inspect /var/log/splunk-ai-bootstrap.log and confirm app tarballs exist in s3://<LicenseBucket>/<SplunkAppsS3Prefix>
