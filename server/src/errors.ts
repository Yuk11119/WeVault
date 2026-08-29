import type { FastifyReply } from "fastify";

export class ApiError extends Error {
  constructor(public readonly code: string, public readonly statusCode: number, message: string) { super(message); }
}
export const fail = (reply: FastifyReply, error: ApiError) => reply.status(error.statusCode).send({ error: { code: error.code, message: error.message } });
export const errors = {
  invalidInput: (message = "Invalid request") => new ApiError("INVALID_INPUT", 400, message),
  invalidCredentials: () => new ApiError("AUTH_INVALID_CREDENTIALS", 401, "Invalid email or password"),
  unauthorized: () => new ApiError("AUTH_UNAUTHORIZED", 401, "Authentication is required"),
  expired: () => new ApiError("AUTH_TOKEN_EXPIRED", 401, "Token has expired"),
  forbidden: () => new ApiError("AUTH_SCOPE_DENIED", 403, "This resource is not available to this device"),
  invitation: () => new ApiError("INVITATION_INVALID", 403, "Invitation is invalid or exhausted"),
  verification: () => new ApiError("EMAIL_VERIFICATION_INVALID", 400, "Verification code is invalid or expired"),
  conflict: (message: string) => new ApiError("CONFLICT", 409, message),
  notFound: () => new ApiError("NOT_FOUND", 404, "Resource not found"),
  cloud: (message: string) => new ApiError("CLOUD_VERIFY_FAILED", 502, message)
};
