import {Request, Response} from "express";
import {AppDataSource} from "../data-source";
import {Post} from "../entity/Post";
import {validatePostInput} from "../validation";

/**
 * Saves given post.
 */
export async function postSaveAction(request: Request, response: Response) {

    // accept only the whitelisted fields: handing request.body to the ORM as it is would let a client
    // send an "id" and make save() overwrite an existing post
    const input = validatePostInput(request.body);
    if (input.errors.length > 0) {
        response.status(400).send({error: "Invalid request body", details: input.errors});
        return;
    }

    // get a post repository to perform operations with post
    const postRepository = AppDataSource.getRepository(Post);

    // create a real post object from the validated fields
    const newPost = postRepository.create(input.value);

    // save received post
    await postRepository.save(newPost);

    // return saved post back
    response.status(201).send(newPost);
}
