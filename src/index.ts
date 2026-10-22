import "reflect-metadata";
import {AppDataSource} from "./data-source";
import {Request, Response, NextFunction} from "express";
import * as express from "express";
import * as bodyParser from "body-parser";
import {AppRoutes} from "./routes";
import {livenessAction, readinessAction, markShuttingDown} from "./health";
import {loadApiToken, requireToken} from "./auth";
import {createMetrics, createMetricsServer} from "./metrics";

const PORT = parseInt(process.env.PORT || "3000", 10);
// Hard limit for graceful shutdown. Keep it below Kubernetes' terminationGracePeriodSeconds.
const SHUTDOWN_TIMEOUT_MS = parseInt(process.env.SHUTDOWN_TIMEOUT_MS || "10000", 10);
// Prometheus metrics are served on their own port, which the Service and the Ingress do not publish. 0 turns them off.
const METRICS_PORT = parseInt(process.env.METRICS_PORT || "9100", 10);

// fail before anything else if the token is missing: a pod that cannot authenticate writes must not become Ready
let apiToken: string;
try {
    apiToken = loadApiToken();
} catch (error) {
    console.error("Failed to start application:", (error as Error).message);
    process.exit(1);
}
const authenticate = requireToken(apiToken);

// connect to the database
// TypeORM creates a connection pool and uses it for the requests
AppDataSource.initialize().then(async () => {

    // create express app
    const app = express();
    app.disable("x-powered-by");

    // request count and duration per route (the probes are left out); registered first so that every route is covered
    const metrics = createMetrics();
    app.use(metrics.middleware);

    // operational endpoints (used by Kubernetes probes)
    app.get("/health", livenessAction);
    app.get("/ready", readinessAction);

    // register all application routes
    // Authentication runs before the body is parsed, so an unauthenticated caller costs us no parsing work.
    const jsonBody = bodyParser.json();
    AppRoutes.forEach(route => {
        const handlers: any[] = [];
        if (route.requiresAuth) {
            handlers.push(authenticate);
        }
        if (route.method !== "get") {
            handlers.push(jsonBody);
        }
        handlers.push((request: Request, response: Response, next: NextFunction) => {
            route.action(request, response).catch(next);
        });
        app[route.method](route.path, ...handlers);
    });

    // central error handler: never leak stack traces to the client
    app.use((error: any, request: Request, response: Response, next: NextFunction) => {
        if (response.headersSent) {
            return next(error);
        }
        const status = error.status >= 400 && error.status < 500 ? error.status : 500;
        if (status === 500) {
            console.error("Unhandled error:", error);
        }
        response.status(status).json({error: status === 500 ? "Internal Server Error" : "Bad Request"});
    });

    // run app
    const server = app.listen(PORT, () => {
        console.log(`Express application is up and running on port ${PORT}`);
    });

    // Metrics are auxiliary: a problem here is logged, it must not take the API down.
    let metricsServer: ReturnType<typeof createMetricsServer> | undefined;
    if (METRICS_PORT > 0) {
        metricsServer = createMetricsServer(metrics.registry);
        metricsServer.on("error", error => console.error("Metrics server error:", error));
        metricsServer.listen(METRICS_PORT, () => {
            console.log(`Metrics are served on port ${METRICS_PORT} at /metrics`);
        });
    }

    // graceful shutdown: stop accepting traffic, finish in-flight requests, close the DB pool
    let shuttingDown = false;
    const shutdown = (signal: string) => {
        if (shuttingDown) {
            return;
        }
        shuttingDown = true;
        console.log(`${signal} received, shutting down gracefully`);
        markShuttingDown();
        if (metricsServer) {
            metricsServer.close();
        }

        const forceExit = setTimeout(() => {
            console.error("Graceful shutdown timed out, forcing exit");
            process.exit(1);
        }, SHUTDOWN_TIMEOUT_MS);
        forceExit.unref();

        server.close(async () => {
            try {
                await AppDataSource.destroy();
            } catch (error) {
                console.error("Error closing database connection:", error);
            }
            process.exit(0);
        });
    };
    process.on("SIGTERM", () => shutdown("SIGTERM"));
    process.on("SIGINT", () => shutdown("SIGINT"));

}).catch(error => {
    // exit with a non-zero code so the orchestrator sees the failure and restarts with backoff
    console.error("Failed to start application:", error);
    process.exit(1);
});
