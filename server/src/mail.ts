import nodemailer from "nodemailer";
import type { Config } from "./config.js";

export interface Mailer { sendVerification(to: string, code: string): Promise<void>; }
export const createMailer = (config: Config): Mailer => {
  const transport = nodemailer.createTransport({ host: config.MAIL_HOST, port: config.MAIL_PORT, secure: config.MAIL_PORT === 465, auth: { user: config.MAIL_USER, pass: config.MAIL_PASSWORD } });
  return { async sendVerification(to, code) {
    await transport.sendMail({ from: config.MAIL_FROM, to, subject: "Verify your WeVault beta account", text: `Your WeVault verification code is ${code}. It expires in 15 minutes.`, html: `<p>Your WeVault verification code is <strong>${code}</strong>.</p><p>It expires in 15 minutes.</p>` });
  }};
};
