// Type shim for ui/dist/* file imports used by the generated ui-bundle.ts.
// `bun build --compile` resolves these to embedded file paths at compile time
// and returns the path (a string) at runtime. TypeScript needs this shim
// because the dist files don't ship with declarations.
declare module "../../ui/dist/*" {
  const path: string;
  export default path;
}
