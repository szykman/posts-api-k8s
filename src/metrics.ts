import * as http from "http";
import {NextFunction, Request, Response} from "express";
import {Counter, Histogram, Registry, collectDefaultMetrics} from "prom-client";

/**
 * Prometheus metrics.
 *
 * They are served by a second, tiny HTTP server on its own port (METRICS_PORT, default 9100), not by the API itself.
 * The Kubernetes Service and the Ingress only publish the API port, so /metrics is reachable from inside the cluster
 * (Prometheus scrapes the pod) and never through the ingress. Putting it on the API port would publish it to the
 * world unless something else filtered it out.
 */

// The probes run every few seconds on every pod; counting them would drown the traffic that matters.
const PROBE_PATHS = ["/health", "/ready"];

// Latency buckets in seconds: 5 ms to 5 s. A request slower than 5 s lands in the +Inf bucket.
const DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5];

export interface Metrics {
    registry: Registry;
    middleware: (request: Request, response: Response, next: NextFunction) => void;
}

/**
 * Creates the registry and the Express middleware that counts requests and measures their duration.
 *
 * The route label is the route *pattern* ("/posts/:id"), never the URL: one series per route instead of one per id,
 * which keeps the number of time series bounded. A request that matches no route is labelled "unmatched" for the
 * same reason (a scanner probing random paths must not create a series per path).
 */
export function createMetrics(options: {defaultMetrics?: boolean} = {}): Metrics {
    const registry = new Registry();
    if (options.defaultMetrics !== false) {
        // process_* and nodejs_* : CPU, memory, open file descriptors, event loop lag, garbage collection
        collectDefaultMetrics({register: registry});
    }

    const labelNames = ["method", "route", "status_code"];
    const requests = new Counter({
        name: "http_requests_total",
        help: "Number of HTTP requests, by method, route pattern and status code.",
        labelNames,
        registers: [registry]
    });
    const duration = new Histogram({
        name: "http_request_duration_seconds",
        help: "HTTP request duration in seconds, by method, route pattern and status code.",
        labelNames,
        buckets: DURATION_BUCKETS,
        registers: [registry]
    });

    const middleware = (request: Request, response: Response, next: NextFunction): void => {
        if (PROBE_PATHS.indexOf(request.path) !== -1) {
            return next();
        }
        const stopTimer = duration.startTimer();
        response.on("finish", () => {
            // request.route is only set once a route matched, which has happened by the time the response finishes
            const labels = {
                method: request.method,
                route: request.route ? String(request.route.path) : "unmatched",
                status_code: String(response.statusCode)
            };
            requests.inc(labels);
            stopTimer(labels);
        });
        next();
    };

    return {registry, middleware};
}

/**
 * The server that exposes the registry. It answers GET /metrics and nothing else.
 */
export function createMetricsServer(registry: Registry): http.Server {
    return http.createServer((request, response) => {
        const path = (request.url || "").split("?")[0];
        if (request.method !== "GET" || path !== "/metrics") {
            response.writeHead(404, {"Content-Type": "text/plain"});
            response.end("not found\n");
            return;
        }
        registry.metrics().then(
            body => {
                response.writeHead(200, {"Content-Type": registry.contentType});
                response.end(body);
            },
            error => {
                console.error("Error collecting metrics:", error);
                response.writeHead(500, {"Content-Type": "text/plain"});
                response.end("error collecting metrics\n");
            }
        );
    });
}
