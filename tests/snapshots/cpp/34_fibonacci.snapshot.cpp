
namespace {

BallDyn fib(int64_t n);

BallDyn fib(int64_t n) {
    auto& input = n;
    if ((n <= static_cast<int64_t>(1))) {
        return BallDyn(n);
    }
    return (fib((n - static_cast<int64_t>(1))) + fib((n - static_cast<int64_t>(2))));
    return BallDyn();
}

} // namespace

int main() {
    for (auto i = static_cast<int64_t>(0); (i < static_cast<int64_t>(8)); (i++)) {
        std::cout << ball_to_string(ball_to_string(fib(i))) << std::endl;
    }
    return 0;
}
