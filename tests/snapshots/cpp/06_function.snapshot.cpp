
namespace {

BallDyn add(int64_t a, int64_t b);
BallDyn square(int64_t x);

BallDyn add(int64_t a, int64_t b) {
    return (a + b);
    return BallDyn();
}

BallDyn square(int64_t x) {
    auto& input = x;
    return (x * x);
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string(add(static_cast<int64_t>(2), static_cast<int64_t>(3)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(square(static_cast<int64_t>(7)))) << std::endl;
    return 0;
}
