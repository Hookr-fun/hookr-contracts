import Ajv from "ajv";
import addFormats from "ajv-formats";

export function createExternalHookSchemaValidator(schema) {
  const ajv = new Ajv({ allErrors: true, strict: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  return (manifest) => {
    if (validate(manifest)) return [];
    return (validate.errors ?? []).map(
      (error) => `${error.instancePath || "/"} ${error.message}`,
    );
  };
}

export function assertExternalHookSchema(manifest, validateSchema, source = "manifest") {
  const errors = validateSchema(manifest);
  if (errors.length) {
    throw new Error(`${source} does not match the external hook schema:\n- ${errors.join("\n- ")}`);
  }
  return manifest;
}
