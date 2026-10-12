import {createHash, timingSafeEqual} from "crypto";
import {Request, Response, NextFunction} from "express";

// Shorter tokens are too easy to guess. `openssl rand -hex 32` (what bootstrap.sh generates) gives 64 characters.
export const MIN_TOKEN_LENGTH = 16;

/**
 * Reads the API token from the environment. The application refuses to start without a valid one
 * ("fail closed"): there is deliberately no switch to turn authentication off.
 */
export function loadApiToken(env: NodeJS.ProcessEnv = process.env): string {
    const token = env.API_TOKEN;
    if (!token) {
        throw new Error("Missing required environment variable API_TOKEN");
    }
    if (token.length < MIN_TOKEN_LENGTH) {
        throw new Error(`API_TOKEN must have at least ${MIN_TOKEN_LENGTH} characters`);
    }
    return token;
}

/**
 * Extracts the token from "Authorization: Bearer <token>". The scheme is case-insensitive (RFC 7235).
 */
export function bearerToken(header: string | undefined): string | undefined {
    if (typeof header !== "string") {
        return undefined;
    }
    const match = /^Bearer +([^ ]+)$/i.exec(header);
    return match ? match[1] : undefined;
}

/**
 * Constant-time comparison. Both values are hashed first so that timingSafeEqual always receives
 * buffers of the same length and the length of the real token is not revealed either.
 */
export function tokensMatch(provided: string, expected: string): boolean {
    const a = createHash("sha256").update(provided).digest();
    const b = createHash("sha256").update(expected).digest();
    return timingSafeEqual(a, b);
}

/**
 * Express middleware that requires "Authorization: Bearer <token>". The answer is the same 401 whether the
 * header is missing, malformed or wrong, so a caller learns nothing about which part failed.
 */
export function requireToken(expected: string) {
    return (request: Request, response: Response, next: NextFunction) => {
        const provided = bearerToken(request.header("authorization"));
        if (provided !== undefined && tokensMatch(provided, expected)) {
            next();
            return;
        }
        response.set("WWW-Authenticate", "Bearer").status(401).json({error: "Unauthorized"});
    };
}
