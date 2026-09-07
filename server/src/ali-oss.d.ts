declare module "ali-oss" {
  type Options = {
    region: string;
    bucket: string;
    endpoint?: string;
    accessKeyId: string;
    accessKeySecret: string;
    stsToken?: string;
  };
  class OSS {
    constructor(options: Options);
    head(name: string): Promise<{ res?: { headers?: Record<string, string | string[] | undefined> } }>;
    put(name: string, file: string, options?: { headers?: Record<string, string> }): Promise<unknown>;
  }
  export default OSS;
}
