import "reflect-metadata";
import * as dotenv from "dotenv";
import {DataSource} from "typeorm";

// Local development defaults. Real environment variables always win (dotenv never overrides them),
// and the file is not part of the Docker image, so in Kubernetes this is a no-op.
dotenv.config({path: "ormconfig.env"});

function required(name: string): string {
    const value = process.env[name];
    if (!value) {
        throw new Error(`Missing required environment variable ${name}`);
    }
    return value;
}

// The single place that describes the database connection. Both the application and the migration CLI
// (typeorm 0.3 requires a DataSource file: `typeorm migration:run -d src/data-source.js`) use it.
// The TYPEORM_* variable names are kept, so the Helm chart keeps the same contract.
export const AppDataSource = new DataSource({
    type: "mysql",
    host: required("TYPEORM_HOST"),
    port: Number(process.env.TYPEORM_PORT || 3306),
    username: required("TYPEORM_USERNAME"),
    password: required("TYPEORM_PASSWORD"),
    database: required("TYPEORM_DATABASE"),
    // The ORM must never alter the schema on its own: changes go through migrations.
    synchronize: false,
    entities: [__dirname + "/entity/*.js"],
    migrations: [__dirname + "/migration/*.js"],
    subscribers: [__dirname + "/subscriber/*.js"],
});
