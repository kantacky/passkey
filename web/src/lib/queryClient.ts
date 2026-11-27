import { QueryClient } from "@tanstack/react-query";

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: (failureCount, error) =>
        failureCount < 2 &&
        !(error instanceof Error && error.name === "ApiError"),
      staleTime: 10_000,
      refetchOnWindowFocus: false,
    },
  },
});
