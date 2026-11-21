import js from "@eslint/js";
import globals from "globals";

export default [
  { ignores: [".build/**", "node_modules/**", "**/*.xcodeproj/**"] },
  js.configs.recommended,
  {
    rules: {
      curly: "error",
      eqeqeq: ["error", "always"],
      "no-var": "error",
      "prefer-const": "error",
      "no-eval": "error",
      "no-implied-eval": "error",
      "no-new-func": "error",
      "no-shadow": "error",
      "no-throw-literal": "error",
      "no-unused-vars": "error",
      "no-use-before-define": "error",
      "no-param-reassign": "error",
      "no-return-assign": "error",
      "no-implicit-coercion": "error",
      "no-console": "error",
      "prefer-promise-reject-errors": "error",
      "require-await": "error",
      radix: "error",
      "dot-notation": "error",
      "no-else-return": "error",
      "no-lonely-if": "error",
      "no-nested-ternary": "error",
      "no-unneeded-ternary": "error",
      "object-shorthand": "error",
      "prefer-template": "error",
      "prefer-arrow-callback": "error",
      "no-useless-return": "error",
      "no-await-in-loop": "error",
    },
  },
  {
    files: ["BridgeCore/Web/**/*.js"],
    languageOptions: { sourceType: "script", globals: globals.browser },
  },
  {
    files: ["scripts/**/*.mjs"],
    languageOptions: { sourceType: "module", globals: globals.node },
  },
];
