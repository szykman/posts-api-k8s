import "reflect-metadata";
import {AppDataSource} from "./data-source";
import {Request, Response, NextFunction} from "express";
import * as express from "express";
import * as bodyParser from "body-parser";
import {AppRoutes} from "./routes";
import {livenessAction, readinessAction, markShuttingDown} from "./health";

const PORT = parseInt(process.env.PORT || "3000", 10);
// Hard limit for graceful shutdown. Keep it below Kubernetes' terminationGracePeriodSeconds.
const SHUTDOWN_TIMEOUT_MS = parseInt(process.env.SHUTDOWN_TIMEOUT_MS || "10000", 10);

// connect to the database
// TypeORM creates a connection pool and uses it for the requests
AppDataSource.initialize().then(async () => {

    // create express app
    const app = express();
    app.disable("x-powered-by");
    app.use(bodyParser.json());

    // operational endpoints (used by Kubernetes probes)
    app.get("/health", livenessAction);
    app.get("/ready", readinessAction);

    // register all application routes
    AppRoutes.forEach(route => {
        app[route.method](route.path, (request: Request, response: Response, next: NextFunction) => {
            route.action(request, response).catch(next);
        });
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

    // graceful shutdown: stop accepting traffic, finish in-flight requests, close the DB pool
    let shuttingDown = false;
    const shutdown = (signal: string) => {
        if (shuttingDown) {
            return;
        }
        shuttingDown = true;
        console.log(`${signal} received, shutting down gracefully`);
        markShuttingDown();

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
