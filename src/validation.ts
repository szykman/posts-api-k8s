/**
 * Input validation for the posts API.
 *
 * Request bodies are never handed to the ORM as they are: save() updates the row when the entity
 * carries a primary key, so a client-supplied "id" would overwrite someone else's data. Only the
 * fields listed here are accepted, and anything else is rejected instead of being silently ignored.
 *
 * Hand-written on purpose: two small entities do not justify a new dependency (and its attack surface).
 */

// Limits follow the database columns: varchar(255) for title and category name, TEXT (65535 bytes) for text.
const TITLE_MAX_LENGTH = 255;
const CATEGORY_NAME_MAX_LENGTH = 255;
const TEXT_MAX_BYTES = 65535;
const MAX_CATEGORIES = 10;
const MAX_REPORTED_ERRORS = 20;
const MAX_INT = 2147483647; // the "id" column is a signed 32-bit int
const ALLOWED_POST_FIELDS = ["title", "text", "categories"];

export interface PostInput {
    title: string;
    text: string;
    categories?: { name: string }[];
}

export interface ValidationResult {
    /** Set only when there are no errors. Contains exactly the whitelisted fields. */
    value?: PostInput;
    errors: string[];
}

function isPlainObject(value: any): boolean {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isBlank(value: any): boolean {
    return typeof value !== "string" || value.trim().length === 0;
}

// Keys come from the client: cut them before echoing them back.
function shown(key: string): string {
    return key.length > 50 ? key.slice(0, 50) + "..." : key;
}

export function validatePostInput(body: any): ValidationResult {
    if (!isPlainObject(body)) {
        return {errors: ["body must be a JSON object"]};
    }

    const errors: string[] = [];

    for (const key of Object.keys(body)) {
        if (ALLOWED_POST_FIELDS.indexOf(key) === -1) {
            errors.push(`unknown field "${shown(key)}"`);
        }
    }

    if (isBlank(body.title)) {
        errors.push("title must be a non-empty string");
    } else if (body.title.length > TITLE_MAX_LENGTH) {
        errors.push(`title must have at most ${TITLE_MAX_LENGTH} characters`);
    }

    if (isBlank(body.text)) {
        errors.push("text must be a non-empty string");
    } else if (Buffer.byteLength(body.text, "utf8") > TEXT_MAX_BYTES) {
        errors.push(`text must have at most ${TEXT_MAX_BYTES} bytes`);
    }

    let categories: { name: string }[] | undefined;
    if (body.categories !== undefined) {
        if (!Array.isArray(body.categories)) {
            errors.push("categories must be an array");
        } else if (body.categories.length > MAX_CATEGORIES) {
            errors.push(`categories must have at most ${MAX_CATEGORIES} items`);
        } else {
            categories = [];
            body.categories.forEach((category: any, index: number) => {
                if (!isPlainObject(category)) {
                    errors.push(`categories[${index}] must be an object`);
                    return;
                }
                for (const key of Object.keys(category)) {
                    if (key !== "name") {
                        errors.push(`categories[${index}]: unknown field "${shown(key)}"`);
                    }
                }
                if (isBlank(category.name)) {
                    errors.push(`categories[${index}].name must be a non-empty string`);
                } else if (category.name.length > CATEGORY_NAME_MAX_LENGTH) {
                    errors.push(`categories[${index}].name must have at most ${CATEGORY_NAME_MAX_LENGTH} characters`);
                } else {
                    categories.push({name: category.name});
                }
            });
        }
    }

    if (errors.length > 0) {
        return {errors: errors.slice(0, MAX_REPORTED_ERRORS)};
    }

    const value: PostInput = {title: body.title, text: body.text};
    if (categories !== undefined) {
        value.categories = categories;
    }
    return {value, errors: []};
}

/**
 * Parses a positive 32-bit integer taken from the URL path.
 * Strict on purpose: without it, "1abc" would be cast by the database to 1 and return post 1.
 */
export function parseId(raw: string): number | undefined {
    if (!/^[1-9][0-9]*$/.test(raw)) {
        return undefined;
    }
    const id = Number(raw);
    return id <= MAX_INT ? id : undefined;
}
