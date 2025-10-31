# IAM Basics

## Title: What is IAM?
IAM (Identity and Access Management) is AWS's system to control who can do what in your AWS account.
It includes users, groups, roles, and policies.

## Title: Creating an IAM role
To create an IAM role you:
1. Open the AWS Console > IAM > Roles.
2. Click Create role.
3. Choose type of trusted entity (e.g., AWS service or another account).
4. Attach policies.
5. Finish and name the role.

## Title: Best practices
- Use least-privilege policies.
- Prefer roles for applications over long-term credentials.
- Use MFA for human users.
