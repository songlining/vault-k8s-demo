# the requirement
I need to further optimise the demo scenario.

The following is from the client's email:

```
Is there a way to see what parameters are available on these actions that I can use to potentially further lock down those rules in future?

For example, we have multiple environments for a project, wherein each creates a vault auth backend called "my-project-<randomstring>". I can mostly restrict this to my workspace policies by allowing access to `sys/auth/my-project-*`, but this would also allow it to talk to the backends created by the other environment workspaces within this project.

These have not been set up with the name of the environment included in the auth backend name, so this will be the case for quite a lot of projects we have. If I could see what other parameters are available to play with, I might be able to find a solution that wouldn't necessitate code changes across the board.

Beyond that, we're still after similar advice for locking down access to paths like identity/groups 
```

# todo
I want you to
1. setup a userpass auth method, that mimics one of the terraform workspaces' OIDC login
2. pre-configure an EntityAlias for the userpass user and add meta data to it.  The meta data is: workspace-name=kubernetes-my_project_123
3. update the file k8s-auth-manager-policy.hcl and template the path based on the meta data in the EntityAlias.  