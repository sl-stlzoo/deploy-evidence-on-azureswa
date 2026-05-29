// =============================================================================
// GetRoles/index.js — Azure Functions v3 HTTP trigger for SWA custom roles
// =============================================================================
// Called by Azure Static Web Apps after a user authenticates via Entra ID.
// Returns an array of custom roles for the authenticated user.
//
// Role assignment logic:
//   1. Reject non-AAD providers (only Entra ID is accepted)
//   2. Verify the user belongs to the configured tenant (AAD_TENANT_ID)
//   3. Optionally restrict to an Entra security group (EVIDENCE_ALLOWED_GROUP_ID)
//   4. Grant evidence_user to all verified members
//   5. Optionally grant evidence_admin to users listed in EVIDENCE_ADMIN_USERS
//
// Docs: https://learn.microsoft.com/en-us/azure/static-web-apps/authentication-custom
// =============================================================================

"use strict";

module.exports = async function getRoles(context, req) {
  const body = req.body;

  context.log(
    "[GetRoles] Provider: %s | User: %s",
    body?.identityProvider ?? "unknown",
    body?.userDetails ?? "unknown"
  );

  // ── Reject non-AAD providers ──────────────────────────────────────────────
  if (!body || body.identityProvider !== "aad") {
    context.log("[GetRoles] Rejected: not an AAD login.");
    context.res = { status: 200, body: { roles: [] } };
    return;
  }

  const requiredTenantId = process.env.AAD_TENANT_ID;
  const claims           = body.claims ?? [];

  // ── Tenant verification ───────────────────────────────────────────────────
  // The 'tid' claim is the tenant ID; reject users from other tenants.
  const tenantClaim = claims.find(
    (c) =>
      c.typ === "tid" ||
      c.typ === "http://schemas.microsoft.com/identity/claims/tenantid"
  );

  if (requiredTenantId) {
    if (!tenantClaim) {
      context.log("[GetRoles] Rejected: no tenant claim present.");
      context.res = { status: 200, body: { roles: [] } };
      return;
    }
    if (tenantClaim.val !== requiredTenantId) {
      context.log(
        "[GetRoles] Rejected: tenant mismatch (expected %s, got %s).",
        requiredTenantId,
        tenantClaim.val
      );
      context.res = { status: 200, body: { roles: [] } };
      return;
    }
  }

  // ── Optional: Group-based access restriction ──────────────────────────────
  // When EVIDENCE_ALLOWED_GROUP_ID is set, only members of that Entra security
  // group receive the evidence_user role.
  // NOTE: Group claims are only included in the token if:
  //   a) The app manifest has "groupMembershipClaims": "SecurityGroup", AND
  //   b) The user is a member of the group
  // See README § Group-Based Access for configuration steps.
  const allowedGroupId = process.env.EVIDENCE_ALLOWED_GROUP_ID;
  if (allowedGroupId) {
    const groupClaims = claims.filter(
      (c) =>
        c.typ === "groups" ||
        c.typ === "http://schemas.microsoft.com/ws/2008/06/identity/claims/groups"
    );
    const memberOfGroup = groupClaims.some((c) => c.val === allowedGroupId);
    if (!memberOfGroup) {
      context.log(
        "[GetRoles] Rejected: user not in required group %s.",
        allowedGroupId
      );
      context.res = { status: 200, body: { roles: [] } };
      return;
    }
  }

  // ── Build role list ───────────────────────────────────────────────────────
  const roles = ["evidence_user"];

  // Optional: promote specific users to evidence_admin
  const adminUsersRaw = process.env.EVIDENCE_ADMIN_USERS ?? "";
  if (adminUsersRaw) {
    const adminUsers = adminUsersRaw
      .split(",")
      .map((u) => u.trim().toLowerCase())
      .filter(Boolean);

    const userEmail = (body.userDetails ?? "").toLowerCase();
    if (adminUsers.includes(userEmail)) {
      roles.push("evidence_admin");
      context.log("[GetRoles] Granted evidence_admin to %s.", userEmail);
    }
  }

  context.log(
    "[GetRoles] Granted roles [%s] to %s.",
    roles.join(", "),
    body.userDetails
  );

  context.res = {
    status: 200,
    body: { roles },
  };
};
