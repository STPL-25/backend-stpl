// plopfile.mjs
import path from "path";

export default function (plop) {
  // helpers
  plop.setHelper("pascalCase", (txt = "") =>
    txt ? txt.charAt(0).toUpperCase() + txt.slice(1) : ""
  );
  plop.setHelper("lowerCase", (txt = "") => (txt || "").toLowerCase());

  const cwd = process.cwd();

  plop.setGenerator("module", {
    description: "Create module folder with lowercase subfolders: controllers, services, repository, routes",
    prompts: [
      {
        type: "input",
        name: "name",
        message: "Module name (PascalCase or camelCase):",
      },
    ],
    actions: [
      // Controller (Plop will create parents automatically)
      {
        type: "add",
        path: path.join(
          cwd,
          "{{pascalCase name}}",
          "controllers",
          "{{pascalCase name}}.controller.js"
        ),
        templateFile: "plop-templates/controller.hbs",
      },

      // Service
      {
        type: "add",
        path: path.join(
          cwd,
          "{{pascalCase name}}",
          "services",
          "{{pascalCase name}}.service.js"
        ),
        templateFile: "plop-templates/service.hbs",
      },

      // Repository (folder name 'repository' singular as you used)
      {
        type: "add",
        path: path.join(
          cwd,
          "{{pascalCase name}}",
          "repository",
          "{{pascalCase name}}.repository.js"
        ),
        templateFile: "plop-templates/repository.hbs",
      },

      // Routes
      {
        type: "add",
        path: path.join(
          cwd,
          "{{pascalCase name}}",
          "routes",
          "{{pascalCase name}}.routes.js"
        ),
        templateFile: "plop-templates/routes.hbs",
      },
    ],
  });
}
