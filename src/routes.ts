import {Request, Response} from "express";
import {postGetAllAction} from "./controller/PostGetAllAction";
import {postGetByIdAction} from "./controller/PostGetByIdAction";
import {postSaveAction} from "./controller/PostSaveAction";

/**
 * All application routes.
 */
export const AppRoutes: {
    path: string,
    method: "get" | "post",
    requiresAuth?: boolean,
    action: (request: Request, response: Response) => Promise<void>
}[] = [
    {
        path: "/posts",
        method: "get",
        action: postGetAllAction
    },
    {
        path: "/posts/:id",
        method: "get",
        action: postGetByIdAction
    },
    {
        path: "/posts",
        method: "post",
        // writes need "Authorization: Bearer <token>"; reads and the probes stay open
        requiresAuth: true,
        action: postSaveAction
    }
];