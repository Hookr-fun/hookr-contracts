import Ajv from "ajv";
import addFormats from "ajv-formats";

export function createPartnerIntegrationSchemaValidator(schema) {
  // Conditional track rules intentionally require properties defined on the root object. AJV's
  // strictRequired lint treats that valid cross-subschema pattern as suspicious, so keep every
  // other strict check while allowing those conditional requirements.
  const ajv = new Ajv({ allErrors: true, strict: true, strictRequired: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  return (brief) => {
    if (validate(brief)) return [];
    return (validate.errors ?? []).map(
      (error) => `${error.instancePath || "/"} ${error.message}`,
    );
  };
}

export function assertPartnerIntegrationSchema(brief, validateSchema, source = "brief") {
  const errors = validateSchema(brief);
  if (errors.length) {
    throw new Error(`${source} does not match the partner integration schema:\n- ${errors.join("\n- ")}`);
  }
  return brief;
}
