
namespace {

BallDyn factorial(int64_t n);
BallDyn fibonacci(int64_t n);

BallDyn factorial(int64_t n) {
    auto& input = n;
    if ((n <= static_cast<int64_t>(1))) {
        return BallDyn(static_cast<int64_t>(1));
    }
    return (n * factorial((n - static_cast<int64_t>(1))));
    return BallDyn();
}

BallDyn fibonacci(int64_t n) {
    auto& input = n;
    if ((n < static_cast<int64_t>(2))) {
        return BallDyn(n);
    }
    return (fibonacci((n - static_cast<int64_t>(1))) + fibonacci((n - static_cast<int64_t>(2))));
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string(factorial(static_cast<int64_t>(5)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(fibonacci(static_cast<int64_t>(10)))) << std::endl;
    return 0;
}
