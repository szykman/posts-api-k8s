import {Request, Response} from "express";
import {getConnection} from "typeorm";

// How long the readiness check waits for the database before giving up.
// Must stay below the Kubernetes probe timeout.
const DB_CHECK_TIMEOUT_MS = 2000;

let shuttingDown = false;

/**
 * Called when the process receives SIGTERM/SIGINT. From this moment on
 * /ready answers 503 so the load balancer stops sending new requests.
 */
export function markShuttingDown(): void {
    shuttingDown = true;
}

/**
 * Liveness: "is the process alive and able to answer HTTP?".
 * Deliberately does NOT touch the database: if the database is down,
 * restarting the application would not fix it and would only make things worse.
 */
export function livenessAction(request: Request, response: Response): void {
    response.status(200).json({status: "ok"});
}

/**
 * Readiness: "can this instance serve traffic right now?".
 * Fails while shutting down or while the database is unreachable.
 */
export async function readinessAction(request: Request, response: Response): Promise<void> {
    if (shuttingDown) {
        response.status(503).json({status: "shutting_down"});
        return;
    }

    try {
        await Promise.race([
            getConnection().query("SELECT 1"),
            new Promise((resolve, reject) =>
                setTimeout(() => reject(new Error("database check timed out")), DB_CHECK_TIMEOUT_MS))
        ]);
        response.status(200).json({status: "ready"});
    } catch (error) {
        console.error("Readiness check failed:", error.message);
        response.status(503).json({status: "database_unavailable"});
    }
}
