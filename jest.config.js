export default {
  testEnvironment: "node",
  transform: {},                          // no transform — native ESM (package.json has "type":"module")
  testMatch: ["**/tests/**/*.test.js"],
  coverageDirectory: "coverage",
  collectCoverageFrom: [
    "src/**/*.js",
    "!src/swagger/**",
  ],
  testTimeout: 15000,
};
