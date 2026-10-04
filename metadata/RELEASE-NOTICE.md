**Deploying these packages.** Deploy them with NeoIPC-Tools' `Deploy-NeoIPCMetadata`, a dry run first, as
[`metadata/dist/README.md`](https://github.com/NeoIPC/Surveillance-Toolkit/blob/main/metadata/dist/README.md)
describes. A plain metadata import, through DHIS2's Import/Export app or a `POST` to `/api/metadata`, is no
substitute: in one request, DHIS2 can link an option group set to none of its groups while reporting success;
repeated over an existing instance, the import fails whole from DHIS2 2.42 on; and on an instance in use, it clears
what the package does not carry, such as the program's organisation units and the members of every org-unit group
and user group.
[`docs/metadata-deployment.md`](https://github.com/NeoIPC/Surveillance-Toolkit/blob/main/docs/metadata-deployment.md)
explains why.
