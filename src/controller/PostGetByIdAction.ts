import {Request, Response} from "express";
import {AppDataSource} from "../data-source";
import {Post} from "../entity/Post";
import {parseId} from "../validation";

/**
 * Loads post by a given id.
 */
export async function postGetByIdAction(request: Request, response: Response) {

    // the id comes from the URL: accept only a plain positive integer
    const id = parseId(request.params.id);
    if (id === undefined) {
        response.status(400).send({error: "id must be a positive integer"});
        return;
    }

    // get a post repository to perform operations with post
    const postRepository = AppDataSource.getRepository(Post);

    // load a post by a given post id
    const post = await postRepository.findOneBy({id});

    // if post was not found return 404 to the client
    if (!post) {
        response.status(404);
        response.end();
        return;
    }

    // return loaded post
    response.send(post);
}
