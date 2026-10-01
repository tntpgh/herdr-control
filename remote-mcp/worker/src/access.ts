// Verifies the Cloudflare Access assertion on /authorize. Access (Google
// Workspace SSO, path-scoped app) authenticates the human before this Worker
// runs; this check makes the Worker fail closed if that app is ever removed,
// widened, or bypassed. Same contract as knowledge-base server/cf_access.py.
import { createRemoteJWKSet, jwtVerify } from "jose";
import type { JWTVerifyGetKey } from "jose";
import type { Env } from "./types";

let jwks: { team: string; set: JWTVerifyGetKey } | null = null;

export interface AccessIdentity {
  email: string;
  sub: string;
}

export async function verifyAccess(request: Request, env: Env): Promise<AccessIdentity | null> {
  const token = request.headers.get("cf-access-jwt-assertion");
  if (!token || !env.ACCESS_AUD || !env.ACCESS_TEAM_DOMAIN) return null;
  const team = env.ACCESS_TEAM_DOMAIN;
  if (!jwks || jwks.team !== team) {
    jwks = { team, set: createRemoteJWKSet(new URL(`https://${team}/cdn-cgi/access/certs`)) };
  }
  try {
    const { payload } = await jwtVerify(token, jwks.set, {
      issuer: `https://${team}`,
      audience: env.ACCESS_AUD,
      algorithms: ["RS256"],
    });
    const email = typeof payload.email === "string" ? payload.email.trim().toLowerCase() : "";
    const allowed = env.ALLOWED_EMAILS.split(",").map((e) => e.trim().toLowerCase()).filter(Boolean);
    if (!email || !allowed.includes(email) || typeof payload.sub !== "string") return null;
    return { email, sub: payload.sub };
  } catch {
    return null;
  }
}
